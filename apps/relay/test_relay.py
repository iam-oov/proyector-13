import asyncio
import base64
import json

import pytest

import relay
from relay import create_app

ID = "testproj0001"
KEY = "k" * 43


@pytest.fixture
async def client(aiohttp_client, tmp_path):
    return await aiohttp_client(create_app(tmp_path / "keys.json"))


async def connect(client, pid=ID, key=KEY):
    ws = await client.ws_connect("/proyector/relay/ws")
    await ws.send_json({"type": "hello", "id": pid, "key": key, "name": "ProyectorBasico"})
    return ws


async def serve_one(ws, status=200, body=b'{"ok":true}'):
    """Answer one request the way the receiver would, and return it."""
    req = await ws.receive_json(timeout=5)
    await ws.send_json({
        "type": "res",
        "rid": req["rid"],
        "status": status,
        "headers": {"content-type": "application/json"},
        "body": base64.b64encode(body).decode(),
    })
    return req


async def test_forwards_request_and_response(client):
    ws = await connect(client)
    assert (await ws.receive_json())["type"] == "welcome"
    call = asyncio.create_task(client.post(
        f"/proyector/api/p/{ID}/play?x=1",
        json={"videoId": "abc"},
        headers={"Authorization": "Bearer t0k3n", "Cookie": "no-pasa"},
    ))
    req = await serve_one(ws)
    res = await call
    assert res.status == 200
    assert await res.json() == {"ok": True}
    assert req["method"] == "POST"
    assert req["path"] == "/play"
    assert req["query"] == "x=1"
    assert req["headers"]["authorization"] == "Bearer t0k3n"
    assert "cookie" not in req["headers"]
    assert base64.b64decode(req["body"]) == b'{"videoId": "abc"}'


async def test_offline_projector_is_503(client):
    res = await client.get(f"/proyector/api/p/{ID}/health")
    assert res.status == 503
    assert (await res.json())["error"] == "proyector desconectado"


async def test_wrong_key_is_rejected_after_first_use(client):
    first = await connect(client)
    await first.receive_json()
    await first.close()
    impostor = await connect(client, key="x" * 43)
    msg = await impostor.receive()
    assert impostor.closed or msg.data == 4003
    assert impostor.close_code == 4003


async def test_reconnect_replaces_old_socket(client):
    old = await connect(client)
    await old.receive_json()
    new = await connect(client)
    await new.receive_json()
    await old.receive()
    assert old.close_code == 4001
    call = asyncio.create_task(client.get(f"/proyector/api/p/{ID}/health"))
    await serve_one(new)
    assert (await call).status == 200


async def test_bad_hello_is_closed(client):
    ws = await client.ws_connect("/proyector/relay/ws")
    await ws.send_json({"type": "hello", "id": "NO VALE", "key": KEY})
    await ws.receive()
    assert ws.close_code == 4000


async def test_version_and_index(client):
    v = await (await client.get("/proyector/version.json")).json()
    assert v["projectors"] == 0
    res = await client.get("/proyector/")
    assert res.status == 200
    assert "Proyector" in await res.text()


async def test_cache_headers(client):
    static = await client.get("/proyector/")
    assert static.headers["cache-control"] == "no-cache"
    api = await client.get(f"/proyector/api/p/{ID}/health")
    assert api.headers["cache-control"] == "no-store"


async def test_index_names_its_version(aiohttp_client, tmp_path, monkeypatch):
    monkeypatch.setenv("RELAY_VERSION", "abc1234")
    client = await aiohttp_client(create_app(tmp_path / "keys.json"))
    html = await (await client.get("/proyector/")).text()
    assert "__VERSION__" not in html
    assert 'src="app.js?v=abc1234"' in html
    assert '<meta name="app-version" content="abc1234">' in html


PAIRING = b'{"ok":true,"id":"testproj0001","name":"ProyectorBasico","token":"fake-test-token-0000"}'


async def test_short_code_roundtrip(client):
    ws = await connect(client)
    await ws.receive_json()
    await ws.send_json({"type": "code", "code": "482913"})
    await asyncio.sleep(0.05)
    # Spaces and dashes typed by the user are fine.
    call = asyncio.create_task(client.post("/proyector/api/code", json={"code": "482 913"}))
    req = await serve_one(ws, body=PAIRING)
    res = await call
    assert res.status == 200
    assert (await res.json())["token"] == "fake-test-token-0000"
    assert req["method"] == "POST" and req["path"] == "/code"
    assert base64.b64decode(req["body"]) == b'{"code": "482913"}'


async def test_short_code_unknown_cleared_and_on_disconnect(client):
    ws = await connect(client)
    await ws.receive_json()
    assert (await client.post("/proyector/api/code", json={"code": "111111"})).status == 404
    assert (await client.post("/proyector/api/code", json={"code": "12"})).status == 400
    await ws.send_json({"type": "code", "code": "482913"})
    await ws.send_json({"type": "code", "code": "555555"})
    await asyncio.sleep(0.05)
    # The old code is gone once the projector shows a new one.
    assert (await client.post("/proyector/api/code", json={"code": "482913"})).status == 404
    await ws.close()
    await asyncio.sleep(0.05)
    assert (await client.post("/proyector/api/code", json={"code": "555555"})).status == 404


async def test_replaced_socket_keeps_successor_code(client):
    old = await connect(client)
    await old.receive_json()
    await old.send_json({"type": "code", "code": "482913"})
    new = await connect(client)
    await new.receive_json()
    await new.send_json({"type": "code", "code": "482913"})
    await old.receive()
    await asyncio.sleep(0.05)
    call = asyncio.create_task(client.post("/proyector/api/code", json={"code": "482913"}))
    await serve_one(new, body=PAIRING)
    assert (await call).status == 200


async def test_short_code_rate_limit(client):
    codes = [(await client.post("/proyector/api/code", json={"code": "000000"})).status for _ in range(6)]
    assert codes == [404] * 5 + [429]


def fake_searcher(results):
    calls = []

    async def search(query):
        calls.append(query)
        return results

    return search, calls


VIDEO = {"id": "dQw4w9WgXcQ", "title": "Song", "channel": "Artist", "thumb": None, "duration": "3:33"}


async def test_search_uses_cache(aiohttp_client, tmp_path):
    search, calls = fake_searcher([VIDEO])
    client = await aiohttp_client(create_app(tmp_path / "keys.json", searcher=search))
    for q in ("  Luis   Miguel ", "luis miguel"):
        res = await client.get("/proyector/api/search", params={"q": q})
        assert res.status == 200
        assert (await res.json())["results"] == [VIDEO]
        assert res.headers["cache-control"] == "no-store"
    # Same query after normalizing: YouTube is asked only once.
    assert calls == ["Luis Miguel"]


async def test_search_needs_query(client):
    res = await client.get("/proyector/api/search", params={"q": "   "})
    assert res.status == 400


async def test_search_rate_limit_and_errors(aiohttp_client, tmp_path):
    async def broken(query):
        raise RuntimeError("down")

    app = create_app(tmp_path / "keys.json", searcher=broken)
    app[relay.SEARCH_LIMIT].limit = 2
    client = await aiohttp_client(app)
    codes = [(await client.get("/proyector/api/search", params={"q": f"q{i}"})).status for i in range(3)]
    assert codes == [502, 502, 429]


def test_parse_youtube_search():
    data = {"contents": {"twoColumnSearchResultsRenderer": {"primaryContents": {"sectionListRenderer": {"contents": [
        {"itemSectionRenderer": {"contents": [
            {"adSlotRenderer": {}},
            {"videoRenderer": {
                "videoId": "dQw4w9WgXcQ",
                "title": {"runs": [{"text": "Never "}, {"text": "Gonna"}]},
                "ownerText": {"runs": [{"text": "Rick"}]},
                "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/a.jpg"}]},
                "lengthText": {"simpleText": "3:33"},
            }},
        ]}},
    ]}}}}}
    assert relay.parse_youtube_search(data) == [{
        "id": "dQw4w9WgXcQ", "title": "Never Gonna", "channel": "Rick",
        "thumb": "https://i.ytimg.com/a.jpg", "duration": "3:33",
    }]
    assert relay.parse_youtube_search({}) == []


# --- Voice assistant ---------------------------------------------------------

TOKEN = "fake-test-token-0000"


def fake_asker(*answers):
    """Answers the Claude calls in order and records what it was asked."""
    asked = []

    async def ask(system, user, schema):
        asked.append(user)
        return answers[len(asked) - 1]

    return ask, asked


def act(action, **kw):
    base = {"action": action, "search_query": "", "prefer": "none", "control": "none",
            "volume": 0, "start_seconds": 0, "seconds": 0, "screen": ""}
    return {**base, **kw}


def projector_answers(ws, routes, seen):
    """Answers every request from `routes` ({(method, path): (status, body)})."""
    async def loop():
        while True:
            req = await ws.receive_json()
            key = (req["method"], req["path"])
            body = base64.b64decode(req["body"])
            seen.append((key, json.loads(body) if body else None, req["headers"].get("authorization")))
            status, out = routes.get(key, (404, {"ok": False}))
            await ws.send_json({"type": "res", "rid": req["rid"], "status": status,
                                "headers": {"content-type": "application/json"},
                                "body": base64.b64encode(json.dumps(out).encode()).decode()})
    return asyncio.create_task(loop())


ROUTES = {
    ("GET", "/volume"): (200, {"ok": True, "level": 5, "max": 15, "muted": False}),
    ("GET", "/health"): (200, {"ok": True, "media": {"title": None, "playing": False}, "queue": {}}),
    ("POST", "/play"): (200, {"ok": True}),
    ("POST", "/volume"): (200, {"ok": True, "level": 9, "max": 15, "muted": False}),
}


async def assistant_client(aiohttp_client, tmp_path, ask, search=None):
    search = search or (lambda q: asyncio.sleep(0, [VIDEO, {**VIDEO, "id": "b" * 11, "title": "Otro"}]))
    client = await aiohttp_client(create_app(tmp_path / "keys.json", searcher=search, asker=ask))
    ws = await connect(client)
    await ws.receive_json()
    return client, ws


def said(text):
    return {"said": text, "selected": ID, "projectors": [{"id": ID, "token": TOKEN, "name": "Sala"}]}


async def test_assistant_plays_and_sets_volume(aiohttp_client, tmp_path):
    ask, asked = fake_asker(
        {"actions": [act("play", search_query="cumbias mix", prefer="long_mix"), act("control", control="volume_up", volume=4)],
         "reply": "Pongo cumbias y subo el volumen"},
        {"index": 1, "reply": "Pongo Otro"},
    )
    client, ws = await assistant_client(aiohttp_client, tmp_path, ask)
    seen = []
    task = projector_answers(ws, ROUTES, seen)
    res = await client.post("/proyector/api/assistant", json=said("pon cumbias y súbele"))
    task.cancel()
    data = await res.json()
    assert res.status == 200, data
    assert data["reply"] == "Pongo cumbias y subo el volumen"
    assert data["played"] == {"id": "b" * 11, "title": "Otro"}
    assert [v["id"] for v in data["results"]] == ["b" * 11, VIDEO["id"]]
    # One line per action for the result card, the volume with before and after.
    assert data["steps"] == [{"text": "Pongo Otro", "ok": True}, {"text": "Volumen 5 → 9", "ok": True}]
    # Context tells Claude the volume scale; the phone's token goes with every call.
    assert "Volumen: 5 de 15" in asked[0]
    assert all(auth == f"Bearer {TOKEN}" for _, _, auth in seen)
    calls = [(k, b) for k, b, _ in seen if k[0] == "POST"]
    assert calls == [(("POST", "/play"), {"videoId": "b" * 11, "title": "Otro"}), (("POST", "/volume"), {"level": 9})]


async def test_assistant_wrong_token_costs_nothing(aiohttp_client, tmp_path):
    ask, asked = fake_asker()
    client, ws = await assistant_client(aiohttp_client, tmp_path, ask)
    task = projector_answers(ws, {("GET", "/volume"): (401, {"ok": False})}, [])
    res = await client.post("/proyector/api/assistant", json=said("pausa"))
    task.cancel()
    assert res.status == 422
    assert "cambió" in (await res.json())["error"]
    assert asked == []


async def test_assistant_unknown_explains(aiohttp_client, tmp_path):
    ask, _ = fake_asker({"actions": [act("unknown")], "reply": "Todavía no puedo apagar el proyector"})
    client, ws = await assistant_client(aiohttp_client, tmp_path, ask)
    task = projector_answers(ws, ROUTES, [])
    res = await client.post("/proyector/api/assistant", json=said("apágalo"))
    task.cancel()
    assert res.status == 422
    assert (await res.json())["error"] == "Todavía no puedo apagar el proyector"


async def test_assistant_needs_key_and_known_projector(aiohttp_client, tmp_path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    client = await aiohttp_client(create_app(tmp_path / "keys.json"))
    assert (await (await client.get("/proyector/version.json")).json())["assistant"] is False
    assert (await client.post("/proyector/api/assistant", json=said("hola"))).status == 503
    # Writing the key file is enough: no restart.
    (tmp_path / "anthropic.key").write_text("sk-test\n")
    assert (await (await client.get("/proyector/version.json")).json())["assistant"] is True
    res = await client.post("/proyector/api/assistant", json={**said("hola"), "selected": "otro0000"})
    assert res.status == 400
    res = await client.post("/proyector/api/assistant", json=said("hola"))
    assert res.status == 422  # projector not connected


async def test_index_spotify_client_id_from_state_file(aiohttp_client, tmp_path, monkeypatch):
    monkeypatch.delenv("SPOTIFY_CLIENT_ID", raising=False)
    client = await aiohttp_client(create_app(tmp_path / "keys.json"))
    html = await (await client.get("/proyector/")).text()
    assert '<meta name="spotify-client-id" content="">' in html
    (tmp_path / "spotify_client_id").write_text("abcdef0123456789abcdef0123456789\n")
    html = await (await client.get("/proyector/")).text()
    assert 'content="abcdef0123456789abcdef0123456789"' in html


def test_queue_gets_a_longer_timeout():
    assert relay.SLOW_PATHS["/queue"] > relay.REQUEST_TIMEOUT


async def test_search_cache_survives_a_restart(aiohttp_client, tmp_path):
    search, calls = fake_searcher([VIDEO])
    first = await aiohttp_client(create_app(tmp_path / "keys.json", searcher=search))
    assert (await first.get("/proyector/api/search", params={"q": "Cumbias"})).status == 200
    await first.close()
    # A new relay (as after a deploy) with the same state directory.
    again = await aiohttp_client(create_app(tmp_path / "keys.json", searcher=search))
    res = await again.get("/proyector/api/search", params={"q": "cumbias"})
    assert (await res.json())["results"] == [VIDEO]
    assert calls == ["Cumbias"]
    assert (tmp_path / "search_cache.sqlite3").exists()


def test_search_cache_expires_and_keeps_the_newest(tmp_path, monkeypatch):
    cache = relay.SearchCache(tmp_path / "c.sqlite3", size=2, ttl=100)
    now = [1000.0]
    monkeypatch.setattr(relay.time, "time", lambda: now[0])
    cache.put("a", [VIDEO])
    now[0] += 1
    cache.put("b", [VIDEO])
    now[0] += 1
    cache.put("c", [VIDEO])
    assert cache.get("a") is None  # the oldest went out
    assert cache.get("c") == [VIDEO]
    now[0] += 101
    assert cache.get("c") is None  # older than the TTL


def test_search_cache_falls_back_to_memory(tmp_path):
    bad = tmp_path / "not-a-db"
    bad.mkdir()  # a directory where the file should be
    cache = relay.SearchCache(bad)
    cache.put("a", [VIDEO])
    assert cache.get("a") == [VIDEO]


async def test_assistant_uses_the_search_cache(aiohttp_client, tmp_path):
    search, calls = fake_searcher([VIDEO])
    ask, _ = fake_asker(
        {"actions": [act("play", search_query="cumbias mix", prefer="long_mix")], "reply": "Pongo cumbias"},
        {"index": 0, "reply": "Pongo Song"},
    )
    client, ws = await assistant_client(aiohttp_client, tmp_path, ask, search)
    assert (await client.get("/proyector/api/search", params={"q": "Cumbias  mix"})).status == 200
    task = projector_answers(ws, ROUTES, [])
    res = await client.post("/proyector/api/assistant", json=said("pon cumbias"))
    task.cancel()
    assert res.status == 200, await res.text()
    assert calls == ["Cumbias mix"]  # the assistant did not ask YouTube again


# --- Buzón -------------------------------------------------------------------

async def test_feedback_is_kept_and_only_read_with_the_code(aiohttp_client, tmp_path, monkeypatch):
    monkeypatch.setenv("FEEDBACK_CODE", "1234567890")
    client = await aiohttp_client(create_app(tmp_path / "keys.json"))
    assert (await client.post("/proyector/api/feedback", json={"text": "  "})).status == 400
    res = await client.post("/proyector/api/feedback", json={"text": "Que diga la hora", "name": "Ana", "version": "abc"})
    assert res.status == 200
    assert (await client.post("/proyector/api/feedback/list", json={"code": "0000000000"})).status == 401
    res = await client.post("/proyector/api/feedback/list", json={"code": "1234567890"})
    items = (await res.json())["items"]
    assert [(i["name"], i["text"]) for i in items] == [("Ana", "Que diga la hora")]
    res = await client.post("/proyector/api/feedback/delete", json={"code": "1234567890", "id": items[0]["id"]})
    assert (await res.json())["ok"] is True
    res = await client.post("/proyector/api/feedback/list", json={"code": "1234567890"})
    assert (await res.json())["items"] == []
    # The page that asks for the code.
    page = await client.get("/proyector/feedback")
    assert page.status == 200 and "Buzón" in await page.text()


async def test_feedback_locks_out_after_wrong_codes(aiohttp_client, tmp_path, monkeypatch):
    monkeypatch.setenv("FEEDBACK_CODE", "1234567890")
    client = await aiohttp_client(create_app(tmp_path / "keys.json"))
    for _ in range(5):
        assert (await client.post("/proyector/api/feedback/list", json={"code": "1111111111"})).status == 401
    # Even the right code waits now.
    assert (await client.post("/proyector/api/feedback/list", json={"code": "1234567890"})).status == 429


async def test_feedback_reading_needs_a_configured_code(aiohttp_client, tmp_path, monkeypatch):
    monkeypatch.delenv("FEEDBACK_CODE", raising=False)
    client = await aiohttp_client(create_app(tmp_path / "keys.json"))
    assert (await client.post("/proyector/api/feedback/list", json={"code": ""})).status == 503
