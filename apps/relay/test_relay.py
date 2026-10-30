import asyncio
import base64

import pytest

from relay import create_app

ID = "aknx93pfcuwu"
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
