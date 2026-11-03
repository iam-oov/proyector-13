"""Voice assistant for the PWA, run on the relay so the Anthropic key never
reaches a browser. Port of apps/control/lib/assistant.dart, cut down to what a
projector can do: play from YouTube, transport and volume, switch projector.

The phone sends the transcribed sentence; Claude turns it into actions; the
relay runs them against the projector over its WebSocket, with the phone's own
Bearer token, exactly like the PWA's buttons do. Prompts and replies are
Spanish (they are shown to the user).
"""

import json
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

from anthropic import AsyncAnthropic

# Same model the control app uses for this job.
MODEL = "claude-haiku-5-5"

Asker = Callable[[str, str, dict], Awaitable[dict]]
# (method, path, json body or None) -> (HTTP status, JSON answer)
Caller = Callable[[str, str, dict | None], Awaitable[tuple[int, dict]]]
Searcher = Callable[[str], Awaitable[list[dict]]]


class Fail(Exception):
    """Something the user should read, in Spanish."""


INTENT_SYSTEM = """
Eres el asistente de voz de una página que controla los proyectores de una casa en México.
Recibes lo que dijo la persona (transcrito por el teléfono, puede traer errores) y el estado
de los proyectores. Una frase puede pedir VARIAS cosas ("pon cumbias y súbele al volumen"):
devuelve una acción por cada una, en el orden en que deben hacerse (primero cambiar de
proyector, luego lo que se pone, al final el volumen). Acciones:

- play: quiere ver o escuchar algo en YouTube (música, videos, canales, también series o
  películas si se pueden buscar en YouTube). En search_query escribe lo que buscarías en YouTube
  para obtener el mejor resultado: conserva nombres de artistas, canales, lugares y títulos.
  Agrega "mix" o "playlist" solo para ambientes o géneros (long_mix); para un video concreto no
  agregues palabras que cambien lo que se busca. En prefer: long_mix para ambientes, géneros,
  estados de ánimo o actividades ("música para la playa", "algo para dormir", "cumbias para
  limpiar"); single_video para una canción o video concreto; latest_from_channel cuando pida lo
  último o lo más reciente de un canal o persona. Si pide empezar en un momento ("desde el
  minuto 15"), pon ese momento en segundos en start_seconds (minuto 15 = 900); si no, 0.
- control: pausar (pause), reanudar (resume), siguiente (next), detener (stop), subir o bajar el
  volumen (volume_up / volume_down; si dice cuánto, "súbele 3" o "bájale tantito", pon en volume
  cuántos pasos: tantito = 1, mucho = 4; si no dice, 0), poner el volumen en un número
  (volume_set: volume en la escala del proyector, que viene en el estado como "N de MAX";
  "volumen 8" es 8, "al 50%" o "a la mitad" es la mitad de MAX, "al máximo" es MAX), silenciar
  (mute) o quitar el silencio (unmute). Para moverse dentro del video que ya suena:
  seek_forward ("adelántalo 5 minutos"), seek_back ("regrésalo un minuto") o seek_to ("ponlo en
  el minuto 20"), con la cantidad o el momento en segundos en seconds.
- switch_screen: quiere usar otro proyector; en screen va el nombre tal como aparece en la
  lista. Si en la misma frase pide algo para ese proyector, switch_screen va primero.
- unknown: no se entiende o no se puede hacer desde aquí (una sola acción unknown). Desde aquí
  todavía no se puede apagar ni prender, poner temporizadores, abrir Netflix u otras apps ni
  cambiar el brillo: para eso usa unknown y dilo en reply.

reply: confirmación corta en español de todo lo pedido, máximo doce palabras
("Pongo cumbias para limpiar y subo el volumen"). Con unknown, reply explica qué sí se puede.
Los campos que no apliquen van vacíos: "" en texto, "none" en listas y 0 en números.
""".strip()

PICK_SYSTEM = """
Eliges el video de YouTube que mejor cumple lo que pidió la persona, de una lista numerada.
Primero, el título tiene que corresponder a lo pedido: los nombres, lugares y palabras concretas
de la frase ("en la México", "capítulo 2", "en vivo") deben estar en el título; entre los que
cumplen, gana el que coincide con más detalles.
- long_mix: prefiere mezclas o playlists largas (30 minutos o más) del ambiente o género pedido
  sobre canciones sueltas; evita shorts, tutoriales, reacciones y videos que no son música.
- single_video: el video oficial del artista y la canción correctos; si no hay oficial, el más
  fiel (letra o en vivo del mismo artista).
- latest_from_channel: el más reciente del canal o persona correctos.
- Si la persona quiere empezar en un momento ("Empieza en"), descarta los videos que duran menos
  que eso. Es solo un filtro: no elijas uno por ser más largo si otro coincide mejor con el título.
Nunca elijas algo que no corresponda a lo pedido. index es el número de la lista.
reply: confirmación corta en español con el título resumido ("Pongo Beach House Mix 2026").
""".strip()

CONTROLS = [
    "pause", "resume", "next", "stop", "volume_up", "volume_down", "volume_set", "mute", "unmute",
    "seek_forward", "seek_back", "seek_to", "none",
]

ACTION_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "action": {"type": "string", "enum": ["play", "control", "switch_screen", "unknown"]},
        "search_query": {"type": "string"},
        "prefer": {"type": "string", "enum": ["long_mix", "single_video", "latest_from_channel", "none"]},
        "control": {"type": "string", "enum": CONTROLS},
        "volume": {"type": "integer"},
        "start_seconds": {"type": "integer"},
        "seconds": {"type": "integer"},
        "screen": {"type": "string"},
    },
    "required": ["action", "search_query", "prefer", "control", "volume", "start_seconds", "seconds", "screen"],
}

INTENT_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {
        "actions": {"type": "array", "items": ACTION_SCHEMA},
        "reply": {"type": "string"},
    },
    "required": ["actions", "reply"],
}

PICK_SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "properties": {"index": {"type": "integer"}, "reply": {"type": "string"}},
    "required": ["index", "reply"],
}


def anthropic_asker(api_key: str) -> Asker:
    # Same limits as the control app: 25 s, one retry.
    client = AsyncAnthropic(api_key=api_key, timeout=25, max_retries=1)

    async def ask(system: str, user: str, schema: dict) -> dict:
        msg = await client.messages.create(
            model=MODEL,
            max_tokens=8000,
            system=system,
            messages=[{"role": "user", "content": user}],
            # Low effort: this is a short classification, and the phone waits.
            output_config={"effort": "low", "format": {"type": "json_schema", "schema": schema}},
        )
        if msg.stop_reason == "refusal":
            raise Fail("El asistente no puede con eso")
        if msg.stop_reason == "max_tokens":
            raise Fail("El asistente no terminó de responder")
        return json.loads("".join(b.text for b in msg.content if b.type == "text"))

    return ask


@dataclass
class Target:
    id: str
    name: str
    call: Caller
    volume: dict | None
    health: dict = field(default_factory=dict)


# (projector id, its token) -> Target, or Fail if offline / token wrong.
Connect = Callable[[str, str], Awaitable[Target]]


def _int(v: object, lo: int, hi: int) -> int:
    try:
        return max(lo, min(hi, int(v)))  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 0


def context_text(projectors: list[dict], target: Target, online: set[str]) -> str:
    rows = [
        f"- {p['name']}"
        + (" (elegido)" if p["id"] == target.id else "")
        + ("" if p["id"] in online else " (no conectado)")
        for p in projectors
    ]
    media = target.health.get("media") or {}
    queue = target.health.get("queue") or {}
    title = media.get("title")
    playing = (
        f"En {target.name} suena: {title}{'' if media.get('playing') else ' (en pausa)'}"
        if title else f"En {target.name} no suena nada"
    )
    v = target.volume
    vol = "" if not v else (
        "\nVolumen: en silencio" if v.get("muted") else f"\nVolumen: {v.get('level')} de {v.get('max')}"
    )
    q = f"\nCola: {queue['info']}" if queue.get("active") and queue.get("info") else ""
    return "Proyectores:\n" + "\n".join(rows) + f"\n{playing}{vol}{q}"


async def run(
    said: str,
    projectors: list[dict],
    target: Target,
    connect: Connect,
    online: set[str],
    ask: Asker,
    search: Searcher,
) -> dict:
    """Understand [said] and do it, starting on [target] (already connected and
    its token checked). Returns what the PWA shows: {reply, selected, played?}.
    Raises Fail when nothing could be done."""
    intent = await ask(INTENT_SYSTEM, f"{context_text(projectors, target, online)}\n\nDijo: «{said}»", INTENT_SCHEMA)
    actions = [a for a in intent.get("actions") or [] if isinstance(a, dict)]
    if not actions:
        raise Fail('No entendí. Prueba "pon música para la playa".')

    state = {"target": target, "played": None}
    done: list[str] = []
    failed: list[str] = []
    for a in actions:
        try:
            r = await _action(said, a, state, projectors, connect, ask, search)
            if r:
                done.append(r)
        except Fail as e:
            failed.append(str(e))

    reply = str(intent.get("reply") or "")
    if any(a.get("action") == "unknown" for a in actions):
        # unknown has nothing to run: its reply is the explanation.
        if not done and not failed:
            raise Fail(reply or 'No entendí. Prueba "pon música para la playa".')
    if not done and len(failed) == 1:
        raise Fail(failed[0])
    if len(actions) == 1 and done:
        reply = done[0]
    if failed:
        reply = f"{reply}. No pude: {'; '.join(failed)}"
    out = {"reply": reply, "selected": state["target"].id}
    if state["played"]:
        out["played"] = state["played"]
    return out


async def _action(said, a, state, projectors, connect, ask, search) -> str | None:
    t: Target = state["target"]
    kind = a.get("action")
    if kind == "switch_screen":
        q = str(a.get("screen") or "").strip().lower()
        match = next(
            (p for p in projectors if q and (q in p["name"].lower() or p["name"].lower() in q)), None,
        )
        if match is None:
            raise Fail(f'No encontré el proyector "{a.get("screen")}"')
        state["target"] = await connect(match["id"], match["token"])
        return f"Ahora en {match['name']}"
    if kind == "play":
        return await _play(said, a, state, ask, search)
    if kind == "control":
        await _control(a, t)
        return None
    return None


async def _play(said, a, state, ask, search) -> str:
    t: Target = state["target"]
    query = str(a.get("search_query") or "").strip()
    if not query:
        raise Fail("No entendí qué poner")
    try:
        videos = await search(query)
    except Exception:
        raise Fail("YouTube no respondió, intenta otra vez") from None
    if not videos:
        raise Fail(f'YouTube no encontró nada para "{query}"')
    start = _int(a.get("start_seconds"), 0, 86400)
    listing = "\n".join(
        f"{i}. {v.get('title')} — {v.get('channel') or ''}" + (f" · dura {v['duration']}" if v.get("duration") else "")
        for i, v in enumerate(videos)
    )
    pick = await ask(
        PICK_SYSTEM,
        f"Pidió: «{said}»\nTipo: {a.get('prefer')}\nBúsqueda: {query}"
        + (f"\nEmpieza en: {start // 60} min {start % 60} s" if start else "")
        + f"\n\nResultados:\n{listing}",
        PICK_SCHEMA,
    )
    v = videos[_int(pick.get("index"), 0, len(videos) - 1)]
    body = {"videoId": v["id"], "title": v.get("title") or ""}
    if start:
        body["start"] = start
    status, res = await t.call("POST", "/play", body)
    if status != 200 or not res.get("ok"):
        raise Fail(res.get("error") or f"{t.name} no pudo ponerlo")
    state["played"] = {"id": v["id"], "title": v.get("title") or ""}
    return str(pick.get("reply") or f"Pongo {v.get('title')}")


async def _control(a: dict, t: Target) -> None:
    c = a.get("control")
    seconds = _int(a.get("seconds"), 0, 86400)
    if c in ("pause", "resume", "stop"):
        req = ("POST", "/media", {"action": {"pause": "pause", "resume": "play", "stop": "stop"}[c]})
    elif c == "next":
        req = ("POST", "/queue", {"next": True})
    elif c in ("seek_forward", "seek_back"):
        req = ("POST", "/media", {"action": "seek", "by": seconds if c == "seek_forward" else -seconds})
    elif c == "seek_to":
        req = ("POST", "/media", {"action": "seek", "to": seconds})
    elif c in ("mute", "unmute"):
        req = ("POST", "/volume", {"mute": c == "mute"})
    elif c in ("volume_up", "volume_down", "volume_set"):
        v = t.volume or {}
        top = _int(v.get("max"), 0, 1000) or 15
        level = _int(v.get("level"), 0, top)
        n = _int(a.get("volume"), 0, 1000)
        if c == "volume_set":
            level = min(n, top)
        else:
            # Steps it said ("súbele 3"); if it did not say, 2.
            level = max(0, min(top, level + (n or 2) * (1 if c == "volume_up" else -1)))
        req = ("POST", "/volume", {"level": level})
    else:
        return
    status, res = await t.call(*req)
    if status == 409:
        raise Fail("No hay un video sonando")
    if status != 200 or not res.get("ok"):
        raise Fail(res.get("error") or f"{t.name} no pudo hacerlo")
    if req[1] == "/volume":
        t.volume = res
