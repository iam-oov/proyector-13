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
from pathlib import Path

from aiohttp import WSMsgType, web

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


# Error messages are shown in the PWA, hence Spanish.
def _error(status: int, message: str) -> web.Response:
    return web.json_response({"ok": False, "error": message}, status=status)


@routes.get(PREFIX)
async def _redirect(_: web.Request) -> web.Response:
    raise web.HTTPPermanentRedirect(f"{PREFIX}/")


@routes.get(PREFIX + "/")
async def _index(_: web.Request) -> web.FileResponse:
    return web.FileResponse(WEB_DIR / "index.html", headers={"cache-control": "no-cache"})


@routes.get(PREFIX + "/version.json")
async def _version_json(request: web.Request) -> web.Response:
    app = request.app
    return web.json_response(
        {"version": app[VERSION], "projectors": len(app[PROJECTORS])},
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
    finally:
        if projectors.get(pid) is me:
            del projectors[pid]
        me.fail_all()
    return ws


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


def create_app(keys_path: Path | None = None) -> web.Application:
    app = web.Application(client_max_size=MAX_BODY)
    app[VERSION] = _version()
    app[PROJECTORS] = {}
    app[KEYS] = KeyStore(
        keys_path
        or Path(os.environ.get("RELAY_STATE_DIR", Path.home() / ".local/state/proyector-relay")) / "keys.json"
    )
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
