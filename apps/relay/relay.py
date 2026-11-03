"""Relay behind valdoh.com/proyector.

Projectors sit behind each home's router, so nothing can reach them from the
outside. Each receiver therefore opens an outbound WebSocket to this relay and
keeps it open. The PWA sends HTTP requests to /proyector/api/p/<id>/<path> and
the relay hands them to the projector over that socket, unchanged: the
receiver serves them with the same routes it uses on the LAN (/play,
/trading...) and checks the QR's Bearer token itself. The relay never sees
those tokens' expected values.

So that nobody can pose as a projector, each receiver carries its own relay
key. The first time an id connects, the relay stores its key; afterwards it
only accepts that key for that id (trust on first use).
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import re
import secrets
import subprocess
import time
from collections import OrderedDict
from collections.abc import Awaitable, Callable
from pathlib import Path

import anthropic
from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

import assistant

ROOT = Path(__file__).resolve().parent
WEB_DIR = ROOT / "web"
PREFIX = "/proyector"

ID_RE = re.compile(r"^[a-z0-9]{6,32}$")
KEY_RE = re.compile(r"^[A-Za-z0-9_-]{32,128}$")

# Headers passed from the phone to the projector, and back.
FORWARD_REQUEST_HEADERS = ("authorization", "content-type")
FORWARD_RESPONSE_HEADERS = ("content-type", "www-authenticate")

REQUEST_TIMEOUT = 15.0
MAX_BODY = 256 * 1024


def _version() -> str:
    """Short SHA of the checkout, or RELAY_VERSION when set."""
    if v := os.environ.get("RELAY_VERSION"):
        return v
    try:
        out = subprocess.run(
            ["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5, check=True,
        )
        return out.stdout.strip() or "dev"
    except (OSError, subprocess.SubprocessError):
        return "dev"


class KeyStore:
    """id -> relay key, in a JSON file outside the checkout (the deploy runs
    `git reset --hard`, which would wipe it)."""

    def __init__(self, path: Path):
        self.path = path
        try:
            self._keys: dict[str, str] = json.loads(path.read_text())
        except (OSError, ValueError):
            self._keys = {}

    def check(self, pid: str, key: str) -> bool:
        """True if the key belongs to that id. An unknown id keeps the first
        key it shows up with."""
        known = self._keys.get(pid)
        if known is None:
            self._keys[pid] = key
            self._save()
            return True
        return secrets.compare_digest(known, key)

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self._keys, indent=1, sort_keys=True))
        tmp.replace(self.path)


class Projector:
    """A connected receiver and its in-flight requests."""

    def __init__(self, pid: str, name: str, ws: web.WebSocketResponse):
        self.id = pid
        self.name = name
        self.ws = ws
        self.pending: dict[str, asyncio.Future] = {}
        # The short pairing code it is showing, if any.
        self.code: str | None = None

    async def request(self, method: str, path: str, query: str, headers: dict, body: bytes) -> dict:
        rid = secrets.token_hex(8)
        fut = asyncio.get_running_loop().create_future()
        self.pending[rid] = fut
        try:
            await self.ws.send_json({
                "type": "req",
                "rid": rid,
                "method": method,
                "path": path,
                "query": query,
                "headers": headers,
                "body": base64.b64encode(body).decode(),
            })
            return await asyncio.wait_for(fut, REQUEST_TIMEOUT)
        finally:
            self.pending.pop(rid, None)

    def resolve(self, msg: dict) -> None:
        fut = self.pending.get(str(msg.get("rid")))
        if fut is not None and not fut.done():
            fut.set_result(msg)

    def fail_all(self) -> None:
        for fut in self.pending.values():
            if not fut.done():
                fut.set_exception(ConnectionError("projector disconnected"))


routes = web.RouteTableDef()

VERSION = web.AppKey("version", str)
PROJECTORS = web.AppKey("projectors", dict)
KEYS = web.AppKey("keys", KeyStore)


@web.middleware
async def _cache_headers(request: web.Request, handler):
    """Cloudflare caches .js/.css/images at the edge by default, which would
    keep serving the old PWA after a deploy. Static files get `no-cache` (the
    browser revalidates with Last-Modified and usually gets a cheap 304); API
    answers are never stored."""
    response = await handler(request)
    if "cache-control" not in response.headers:
        api = request.path.startswith(PREFIX + "/api/")
        response.headers["cache-control"] = "no-store" if api else "no-cache"
    return response


# Error messages are shown in the PWA, hence Spanish.
def _error(status: int, message: str) -> web.Response:
    return web.json_response({"ok": False, "error": message}, status=status)


@routes.get(PREFIX)
async def _redirect(_: web.Request) -> web.Response:
    raise web.HTTPPermanentRedirect(f"{PREFIX}/")


@routes.get(PREFIX + "/")
async def _index(request: web.Request) -> web.Response:
    # The page names its own version and loads app.js/style.css with ?v=, so
    # a phone never mixes a new page with cached old code, and the version on
    # screen is the code that is really running.
    html = (WEB_DIR / "index.html").read_text().replace("__VERSION__", request.app[VERSION])
    return web.Response(text=html, content_type="text/html", headers={"cache-control": "no-cache"})


@routes.get(PREFIX + "/version.json")
async def _version_json(request: web.Request) -> web.Response:
    app = request.app
    return web.json_response(
        {"version": app[VERSION], "projectors": len(app[PROJECTORS]), "assistant": bool(_assistant_key(app))},
        headers={"cache-control": "no-store"},
    )


@routes.get(PREFIX + "/relay/ws")
async def _projector_ws(request: web.Request) -> web.WebSocketResponse:
    """The receiver introduces itself with {"type":"hello","id","key","name"}
    and then answers the requests it is sent."""
    ws = web.WebSocketResponse(heartbeat=30, max_msg_size=MAX_BODY * 2)
    await ws.prepare(request)
    projectors: dict[str, Projector] = request.app[PROJECTORS]
    store: KeyStore = request.app[KEYS]

    try:
        hello = await ws.receive_json(timeout=10)
    except (TypeError, ValueError, asyncio.TimeoutError):
        await ws.close(code=4000, message=b"hello expected")
        return ws
    pid, key = str(hello.get("id", "")), str(hello.get("key", ""))
    if hello.get("type") != "hello" or not ID_RE.match(pid) or not KEY_RE.match(key):
        await ws.close(code=4000, message=b"invalid hello")
        return ws
    if not store.check(pid, key):
        await ws.close(code=4003, message=b"wrong relay key")
        return ws

    # A projector reconnecting after a network blip may still have a stale
    # socket here; the new one wins.
    old = projectors.get(pid)
    if old is not None:
        old.fail_all()
        await old.ws.close(code=4001, message=b"replaced")
    me = Projector(pid, str(hello.get("name", ""))[:40], ws)
    projectors[pid] = me
    await ws.send_json({"type": "welcome", "version": request.app[VERSION]})

    try:
        async for msg in ws:
            if msg.type != WSMsgType.TEXT:
                continue
            try:
                data = json.loads(msg.data)
            except ValueError:
                continue
            if data.get("type") == "res":
                me.resolve(data)
            elif data.get("type") == "code":
                _set_code(request.app[CODES], me, data.get("code"))
    finally:
        if projectors.get(pid) is me:
            del projectors[pid]
        _set_code(request.app[CODES], me, None)
        me.fail_all()
    return ws


# --- Short pairing code ---------------------------------------------------
#
# While "Vincular teléfono" is on screen the projector shows a 6-digit code
# and tells the relay over its WebSocket ({"type":"code","code":"482913"} or
# null). A phone types it in the PWA; the relay only routes by it and asks
# that projector, which checks the code itself (one use, short life, rotates
# after misses) and answers the same id/name/token the QR carries.

CODE_RE = re.compile(r"^\d{6}$")
# Misses never reach the projector, so this per-IP limit is what stops
# guessing through the relay.
CODE_RATE = 5
CODE_RATE_WINDOW = 60.0


def _set_code(codes: dict, projector: Projector, code: object) -> None:
    # Compare objects, not ids: a replaced socket must not drop the code its
    # successor registered.
    if projector.code and codes.get(projector.code) is projector:
        del codes[projector.code]
    projector.code = code if isinstance(code, str) and CODE_RE.match(code) else None
    if projector.code:
        codes[projector.code] = projector


@routes.post(PREFIX + "/api/code")
async def _redeem_code(request: web.Request) -> web.Response:
    try:
        data = await request.json()
    except ValueError:
        data = None
    raw = data.get("code") if isinstance(data, dict) else None
    code = re.sub(r"\D", "", str(raw or ""))
    if not CODE_RE.match(code):
        return _error(400, "Escribe los 6 números que salen en el proyector")
    who = request.headers.get("cf-connecting-ip") or request.remote or "?"
    if not request.app[CODE_LIMIT].allow(who):
        return _error(429, "Demasiados intentos. Espera un minuto.")
    projector = request.app[CODES].get(code)
    if projector is None:
        return _error(404, "Ese código no existe o ya caducó. Revisa que el proyector siga en Vincular teléfono.")
    try:
        res = await projector.request(
            "POST", "/code", "", {"content-type": "application/json"}, json.dumps({"code": code}).encode(),
        )
    except asyncio.TimeoutError:
        return _error(504, "El proyector no contestó a tiempo")
    except ConnectionError:
        return _error(503, "El proyector se desconectó")
    return _reply(res)


@routes.route("*", PREFIX + "/api/p/{pid}/{path:.*}")
async def _forward(request: web.Request) -> web.Response:
    """Pass the phone's request to the projector and return its response."""
    pid = request.match_info["pid"]
    projector = request.app[PROJECTORS].get(pid)
    if projector is None:
        return _error(503, "proyector desconectado")
    if request.content_length and request.content_length > MAX_BODY:
        return _error(413, "petición demasiado grande")
    body = await request.read()
    if len(body) > MAX_BODY:
        return _error(413, "petición demasiado grande")
    headers = {h: request.headers[h] for h in FORWARD_REQUEST_HEADERS if h in request.headers}
    try:
        res = await projector.request(
            request.method, "/" + request.match_info["path"], request.query_string, headers, body,
        )
    except asyncio.TimeoutError:
        return _error(504, "el proyector no contestó a tiempo")
    except ConnectionError:
        return _error(503, "proyector desconectado")
    return _reply(res)


def _reply(res: dict) -> web.Response:
    """The projector's answer as an HTTP response."""
    try:
        out = base64.b64decode(res.get("body") or "")
    except ValueError:
        return _error(502, "respuesta inválida del proyector")
    res_headers = res.get("headers") or {}
    return web.Response(
        status=int(res.get("status", 502)),
        body=out,
        headers={h: str(res_headers[h]) for h in FORWARD_RESPONSE_HEADERS if h in res_headers},
    )


# --- YouTube search -------------------------------------------------------
#
# The PWA cannot call youtube.com itself (no CORS headers), so the relay
# searches for it. Same request as searchYouTubeWeb in packages/shared: the
# web client's InnerTube endpoint, which has no daily quota.

YOUTUBE_SEARCH_URL = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
SEARCH_MAX_RESULTS = 8
SEARCH_CACHE_SIZE = 300
SEARCH_CACHE_TTL = 6 * 3600
# Per client IP, so that nobody turns the relay into a free search proxy and
# gets the server's IP blocked by YouTube.
SEARCH_RATE = 30
SEARCH_RATE_WINDOW = 60.0

Searcher = Callable[[str], Awaitable[list[dict]]]


def parse_youtube_search(data: dict, limit: int = SEARCH_MAX_RESULTS) -> list[dict]:
    """Video results from an InnerTube search answer, in the shape the PWA uses."""

    def runs(o: object) -> str:
        items = o.get("runs") if isinstance(o, dict) else None
        return "".join(str(r.get("text", "")) for r in items or [])

    sections = (
        data.get("contents", {})
        .get("twoColumnSearchResultsRenderer", {})
        .get("primaryContents", {})
        .get("sectionListRenderer", {})
        .get("contents", [])
    )
    out: list[dict] = []
    for section in sections:
        for item in section.get("itemSectionRenderer", {}).get("contents", []):
            v = item.get("videoRenderer")
            if not v or not v.get("videoId"):
                continue
            thumbs = v.get("thumbnail", {}).get("thumbnails") or [{}]
            out.append({
                "id": v["videoId"],
                "title": runs(v.get("title")),
                "channel": runs(v.get("ownerText")),
                "thumb": thumbs[0].get("url"),
                "duration": v.get("lengthText", {}).get("simpleText"),
            })
            if len(out) >= limit:
                return out
    return out


def youtube_searcher(session: ClientSession) -> Searcher:
    async def search(query: str) -> list[dict]:
        payload = {
            "context": {"client": {"clientName": "WEB", "clientVersion": "2.20251001.00.00", "hl": "es", "gl": "MX"}},
            "query": query,
            # "Videos only" filter.
            "params": "EgIQAQ%3D%3D",
        }
        async with session.post(
            YOUTUBE_SEARCH_URL,
            json=payload,
            headers={"user-agent": "Mozilla/5.0"},
            timeout=ClientTimeout(total=8),
        ) as r:
            if r.status != 200:
                raise RuntimeError(f"YouTube {r.status}")
            return parse_youtube_search(await r.json(content_type=None))

    return search


class SearchCache:
    """Last answers by normalized query, so repeated searches skip YouTube."""

    def __init__(self, size: int = SEARCH_CACHE_SIZE, ttl: float = SEARCH_CACHE_TTL):
        self.size, self.ttl = size, ttl
        self._items: OrderedDict[str, tuple[float, list[dict]]] = OrderedDict()

    def get(self, key: str) -> list[dict] | None:
        hit = self._items.get(key)
        if hit is None or time.monotonic() - hit[0] > self.ttl:
            return None
        self._items.move_to_end(key)
        return hit[1]

    def put(self, key: str, results: list[dict]) -> None:
        self._items[key] = (time.monotonic(), results)
        self._items.move_to_end(key)
        while len(self._items) > self.size:
            self._items.popitem(last=False)


class RateLimiter:
    def __init__(self, limit: int = SEARCH_RATE, window: float = SEARCH_RATE_WINDOW):
        self.limit, self.window = limit, window
        self._hits: dict[str, list[float]] = {}

    def allow(self, who: str) -> bool:
        now = time.monotonic()
        hits = [t for t in self._hits.get(who, []) if now - t < self.window]
        allowed = len(hits) < self.limit
        if allowed:
            hits.append(now)
        self._hits[who] = hits
        if len(self._hits) > 10_000:
            # Forget idle clients so the table cannot grow forever.
            self._hits = {k: v for k, v in self._hits.items() if v and now - v[-1] < self.window}
        return allowed


SEARCHER = web.AppKey("searcher", object)
SEARCH_CACHE = web.AppKey("search_cache", SearchCache)
SEARCH_LIMIT = web.AppKey("search_limit", RateLimiter)
CODES = web.AppKey("codes", dict)
CODE_LIMIT = web.AppKey("code_limit", RateLimiter)


@routes.get(PREFIX + "/api/search")
async def _search(request: web.Request) -> web.Response:
    query = " ".join(request.query.get("q", "").split())[:120]
    if not query:
        return _error(400, "escribe qué buscar")
    # Behind Cloudflare the client's address comes in this header.
    who = request.headers.get("cf-connecting-ip") or request.remote or "?"
    key = query.lower()
    cache: SearchCache = request.app[SEARCH_CACHE]
    results = cache.get(key)
    if results is None:
        if not request.app[SEARCH_LIMIT].allow(who):
            return _error(429, "demasiadas búsquedas, espera un minuto")
        try:
            results = await request.app[SEARCHER](query)
        except Exception:
            return _error(502, "YouTube no respondió, intenta otra vez")
        if results:
            cache.put(key, results)
    return web.json_response({"ok": True, "results": results})


async def _http_session(app: web.Application):
    """Shared client session for the YouTube searches, unless a test injected
    its own searcher."""
    if app[SEARCHER] is not None:
        yield
        return
    async with ClientSession() as session:
        app[SEARCHER] = youtube_searcher(session)
        yield


# --- Voice assistant ------------------------------------------------------
#
# The PWA sends the sentence it heard; assistant.py asks Claude what to do and
# the relay does it on the projector. The Anthropic key stays on the server:
# ANTHROPIC_API_KEY, or the file anthropic.key in the state directory (read
# on demand, so writing the file is enough, no restart).

ASSISTANT_RATE = 10
ASSISTANT_RATE_WINDOW = 60.0
# Every sentence costs money: a hard cap per day for the whole relay.
ASSISTANT_DAILY = 300
TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{16,128}$")

STATE_DIR = web.AppKey("state_dir", Path)
# One-item list: filled on the first request after the key appears (an
# app's state cannot be replaced once it is running).
ASKER = web.AppKey("asker", list)
ASSISTANT_LIMIT = web.AppKey("assistant_limit", RateLimiter)
ASSISTANT_DAY = web.AppKey("assistant_day", list)


def _assistant_key(app: web.Application) -> str:
    if key := os.environ.get("ANTHROPIC_API_KEY", "").strip():
        return key
    try:
        return (app[STATE_DIR] / "anthropic.key").read_text().strip()
    except OSError:
        return ""


def _asker(app: web.Application) -> assistant.Asker | None:
    holder = app[ASKER]
    if holder[0] is None and (key := _assistant_key(app)):
        holder[0] = assistant.anthropic_asker(key)
    return holder[0]


async def _call(projector: Projector, token: str, method: str, path: str, body: dict | None) -> tuple[int, dict]:
    headers = {"authorization": f"Bearer {token}"}
    raw = b""
    if body is not None:
        headers["content-type"] = "application/json"
        raw = json.dumps(body).encode()
    try:
        res = await projector.request(method, path, "", headers, raw)
    except asyncio.TimeoutError:
        raise assistant.Fail(f"{projector.name or 'El proyector'} no contestó a tiempo") from None
    except ConnectionError:
        raise assistant.Fail(f"{projector.name or 'El proyector'} se desconectó") from None
    try:
        data = json.loads(base64.b64decode(res.get("body") or "") or b"{}")
    except ValueError:
        data = {}
    return int(res.get("status", 502)), data if isinstance(data, dict) else {}


@routes.post(PREFIX + "/api/assistant")
async def _assistant(request: web.Request) -> web.Response:
    app = request.app
    ask = _asker(app)
    if ask is None:
        return _error(503, "El asistente no está configurado en el servidor")
    try:
        data = await request.json()
    except ValueError:
        data = None
    if not isinstance(data, dict):
        return _error(400, "petición inválida")
    said = " ".join(str(data.get("said") or "").split())[:300]
    if not said:
        return _error(400, "No te escuché")
    projectors = [
        {"id": p["id"], "token": p["token"], "name": str(p.get("name") or "Proyector")[:40]}
        for p in (data.get("projectors") or [])[:20]
        if isinstance(p, dict) and ID_RE.match(str(p.get("id", ""))) and TOKEN_RE.match(str(p.get("token", "")))
    ]
    selected = str(data.get("selected") or "")
    if not any(p["id"] == selected for p in projectors):
        return _error(400, "Elige un proyector")

    who = request.headers.get("cf-connecting-ip") or request.remote or "?"
    if not app[ASSISTANT_LIMIT].allow(who):
        return _error(429, "Demasiadas peticiones, espera un minuto")
    day = time.strftime("%Y-%m-%d")
    if app[ASSISTANT_DAY][0] != day:
        app[ASSISTANT_DAY][:] = [day, 0]
    if app[ASSISTANT_DAY][1] >= ASSISTANT_DAILY:
        return _error(429, "El asistente ya se usó mucho hoy, intenta mañana")

    connected: dict[str, Projector] = app[PROJECTORS]

    async def connect(pid: str, token: str) -> assistant.Target:
        name = next((p["name"] for p in projectors if p["id"] == pid), "El proyector")
        proj = connected.get(pid)
        if proj is None:
            raise assistant.Fail(f"{name} no está conectado")

        async def call(method: str, path: str, body: dict | None) -> tuple[int, dict]:
            return await _call(proj, token, method, path, body)

        # An authenticated call first: a wrong token costs no Claude tokens.
        status, volume = await call("GET", "/volume", None)
        if status == 401:
            raise assistant.Fail(f"El código de {name} cambió: escanea su QR otra vez")
        _, health = await call("GET", "/health", None)
        return assistant.Target(pid, name, call, volume if status == 200 else None, health)

    try:
        # Verify the chosen projector before counting the sentence.
        first = next(p for p in projectors if p["id"] == selected)
        target = await connect(first["id"], first["token"])
        app[ASSISTANT_DAY][1] += 1
        out = await assistant.run(
            said, projectors, target, connect, set(connected), ask, app[SEARCHER],
        )
    except assistant.Fail as e:
        return _error(422, str(e))
    except anthropic.AuthenticationError:
        return _error(503, "La key del asistente no es válida")
    except anthropic.RateLimitError:
        return _error(429, "El asistente está ocupado, intenta en un momento")
    except (anthropic.APIConnectionError, anthropic.APITimeoutError):
        return _error(504, "El asistente no contestó, intenta otra vez")
    except anthropic.APIStatusError:
        return _error(502, "El asistente falló, intenta otra vez")
    return web.json_response({"ok": True, "heard": said, **out})


def create_app(
    keys_path: Path | None = None,
    searcher: Searcher | None = None,
    asker: assistant.Asker | None = None,
) -> web.Application:
    app = web.Application(client_max_size=MAX_BODY, middlewares=[_cache_headers])
    app[VERSION] = _version()
    app[PROJECTORS] = {}
    app[KEYS] = KeyStore(
        keys_path
        or Path(os.environ.get("RELAY_STATE_DIR", Path.home() / ".local/state/proyector-relay")) / "keys.json"
    )
    app[SEARCHER] = searcher
    app[SEARCH_CACHE] = SearchCache()
    app[SEARCH_LIMIT] = RateLimiter()
    app[CODES] = {}
    app[CODE_LIMIT] = RateLimiter(CODE_RATE, CODE_RATE_WINDOW)
    app[STATE_DIR] = app[KEYS].path.parent
    app[ASKER] = [asker]
    app[ASSISTANT_LIMIT] = RateLimiter(ASSISTANT_RATE, ASSISTANT_RATE_WINDOW)
    app[ASSISTANT_DAY] = ["", 0]
    app.cleanup_ctx.append(_http_session)
    app.add_routes(routes)
    # The rest of the PWA's files (js, css, icons, manifest).
    app.router.add_static(PREFIX + "/", WEB_DIR, append_version=False)
    return app


if __name__ == "__main__":
    web.run_app(
        create_app(),
        host=os.environ.get("RELAY_HOST", "127.0.0.1"),
        port=int(os.environ.get("RELAY_PORT", "8090")),
    )
