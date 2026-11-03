'use strict';

// Projector control PWA served by the relay at www.valdoh.com/proyector.
// Same design and features as apps/control, minus trading, TVs and the sleep
// timer. Every projector call goes through the relay (api/p/<id>/<path>),
// which hands it to the projector over its WebSocket; the projector checks the
// QR's Bearer token itself. UI strings are Spanish.

const $ = (id) => document.getElementById(id);
const POLL_MS = 3000;
const SEEK_S = 10;

// ---------------------------------------------------------------------------
// Storage. localStorage may throw (private mode) or come back empty; the app
// must still work for this visit.

const STORE_KEY = 'proyector.v1';
const ID_RE = /^[a-z0-9]{8,32}$/;
const TOKEN_RE = /^[A-Za-z0-9_-]{16,128}$/;

function validProjector(p) {
  return p && ID_RE.test(p.id) && TOKEN_RE.test(p.token) && typeof p.name === 'string';
}

function loadStore() {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    const data = raw ? JSON.parse(raw) : {};
    return {
      projectors: Array.isArray(data.projectors) ? data.projectors.filter(validProjector) : [],
      selected: typeof data.selected === 'string' ? data.selected : null,
      phoneName: typeof data.phoneName === 'string' ? data.phoneName : '',
      lastSent: data.lastSent && typeof data.lastSent === 'object' ? data.lastSent : {},
      autoFollow: data.autoFollow !== false,
      pinned: Array.isArray(data.pinned) ? data.pinned.filter((x) => typeof x === 'string') : [],
    };
  } catch {
    return { projectors: [], selected: null, phoneName: '', lastSent: {}, autoFollow: true, pinned: [] };
  }
}

function saveStore() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(store));
  } catch {
    // Not persisted; nothing else to do.
  }
}

const store = loadStore();

// Live state. status per projector id: 'online' | 'offline' | 'unauthorized'
// (missing = not checked yet).
const status = {};
let health = null;
let volume = null;
let checked = false;
let tab = 'now';
let view = 'tabs';
let ticks = 0;
let volDragging = false;
const announced = new Set();

function current() {
  return store.projectors.find((p) => p.id === store.selected) || store.projectors[0] || null;
}

function stateOf(p) {
  return p ? status[p.id] || 'unknown' : 'unknown';
}

// ---------------------------------------------------------------------------
// Pairing payload. The projector's QR is a link to this page with the payload
// after the # (so the token never reaches the server):
//   https://www.valdoh.com/proyector/#pair?v=1&id=…&n=…&h=…&p=…&t=…
// The old form proyector://pair?… is accepted too. h/p (LAN address) are kept
// only so "Copiar código" stays readable by the Flutter app.

function parsePairing(raw) {
  let text = String(raw || '').trim();
  const hash = text.indexOf('#pair?');
  if (hash > 0) text = text.slice(hash);
  if (!/^proyector:\/\/pair\?/i.test(text) && !text.startsWith('#pair?') && !text.startsWith('pair?')) {
    throw new Error('Ese código no es de un proyector');
  }
  const params = new URLSearchParams(text.slice(text.indexOf('?') + 1));
  const v = Number(params.get('v'));
  if (!v || v > 1) throw new Error('Código de una versión nueva: actualiza el proyector');
  const id = params.get('id') || '';
  const token = params.get('t') || '';
  if (!ID_RE.test(id) || !TOKEN_RE.test(token)) throw new Error('El código está incompleto');
  const name = (params.get('n') || 'Proyector').trim().slice(0, 40) || 'Proyector';
  const out = { id, token, name };
  const host = (params.get('h') || '').trim();
  const port = Number(params.get('p'));
  if (host && !/\s/.test(host) && port > 0 && port < 65536) Object.assign(out, { host, port });
  return out;
}

function pairingLink(p) {
  const q = new URLSearchParams({ v: '1', id: p.id, n: p.name });
  if (p.host && p.port) {
    q.set('h', p.host);
    q.set('p', String(p.port));
  }
  q.set('t', p.token);
  return `${location.origin}${location.pathname}#pair?${q}`;
}

// ---------------------------------------------------------------------------
// Relay calls.

async function api(p, path, { method = 'GET', body } = {}) {
  const headers = { authorization: `Bearer ${p.token}` };
  if (body !== undefined) headers['content-type'] = 'application/json';
  let res;
  try {
    res = await fetch(`api/p/${p.id}/${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store',
    });
  } catch {
    return { status: 0, data: { ok: false, error: 'Sin conexión a internet' } };
  }
  let data = {};
  try {
    data = await res.json();
  } catch {
    // Not JSON (e.g. a Cloudflare error page).
  }
  if (res.status === 503) status[p.id] = 'offline';
  else if (res.status === 401) status[p.id] = 'unauthorized';
  // /health is public, so only an authenticated answer proves the token.
  else if (path !== 'health' && res.status < 500) status[p.id] = 'online';
  return { status: res.status, data };
}

function errorText(r, p) {
  if (r.status === 401) return `El código de ${p.name} cambió: escanea su QR otra vez`;
  if (r.status === 503) return `${p.name} no está conectado`;
  if (r.status === 504) return `${p.name} no contestó a tiempo`;
  return (r.data && r.data.error) || 'Algo falló, intenta otra vez';
}

// ---------------------------------------------------------------------------
// Toast (the app's floating SnackBar).

let toastTimer = 0;
function toast(text, { error = false } = {}) {
  const el = $('toast');
  el.textContent = text;
  el.classList.toggle('error', error);
  el.hidden = false;
  clearTimeout(toastTimer);
  // Long notices need more time to be read.
  toastTimer = setTimeout(() => { el.hidden = true; }, text.length > 90 ? 6000 : error ? 4500 : 3000);
}

// ---------------------------------------------------------------------------
// Sheets.

const sheets = ['sheet-screens', 'sheet-menu', 'sheet-add', 'sheet-paste', 'sheet-phone', 'sheet-rename', 'sheet-confirm', 'sheet-others'];
let afterPhoneName = null;

function openSheet(id) {
  for (const s of sheets) $(s).hidden = s !== id;
  $('scrim').hidden = false;
}

function closeSheets() {
  for (const s of sheets) $(s).hidden = true;
  $('scrim').hidden = true;
  afterPhoneName = null;
}

$('scrim').addEventListener('click', closeSheets);

function defaultPhoneName() {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua)) return 'iPad';
  if (/Android/.test(ua)) return 'Android';
  return 'Mi teléfono';
}

function askPhoneName(then) {
  $('phone-input').value = store.phoneName || defaultPhoneName();
  openSheet('sheet-phone');
  afterPhoneName = then;
  $('phone-input').focus();
}

$('phone-save').addEventListener('click', () => {
  const name = $('phone-input').value.trim().slice(0, 40);
  if (!name) {
    $('phone-input').focus();
    return;
  }
  store.phoneName = name;
  saveStore();
  // Every projector shows the new name once it hears from this phone again.
  announced.clear();
  const then = afterPhoneName;
  closeSheets();
  renderAddSheet();
  if (then) then();
  else refresh();
});

// ---------------------------------------------------------------------------
// Adding a projector.

async function addProjector(payload) {
  if (!store.phoneName) {
    askPhoneName(() => addProjector(payload));
    return;
  }
  toast(`Conectando con ${payload.name}…`);
  const r = await api(payload, 'pair', { method: 'POST', body: { phoneName: store.phoneName } });
  if (r.status !== 200 || !r.data.ok) {
    if (r.status === 503) {
      toast(`${payload.name} no está conectado a internet. Préndelo y vuelve a intentar.`, { error: true });
    } else if (r.status === 401) {
      toast('Ese código ya no sirve: en el proyector abre "Vincular teléfono" y escanea el QR nuevo', { error: true });
    } else {
      toast(errorText(r, payload), { error: true });
    }
    return;
  }
  const entry = { ...payload, name: String(r.data.name || payload.name).slice(0, 40) };
  const at = store.projectors.findIndex((p) => p.id === entry.id);
  if (at >= 0) store.projectors[at] = entry;
  else store.projectors.push(entry);
  announced.add(entry.id);
  status[entry.id] = 'online';
  closeSheets();
  toast(`Pantalla "${entry.name}" guardada`);
  select(entry.id);
}

function addFromText(text) {
  try {
    addProjector(parsePairing(text));
  } catch (e) {
    toast(e.message, { error: true });
  }
}

// The 6-digit code the projector shows on its pairing panel. The relay finds
// the projector showing it and hands back the same id/token as the QR.

let redeeming = false;

function openCodeSheet() {
  $('code-input').value = '';
  $('code-error').hidden = true;
  $('link-box').hidden = true;
  $('link-toggle').hidden = false;
  $('paste-input').value = '';
  openSheet('sheet-paste');
  // Synchronously, inside the tap: iOS only raises the keyboard then.
  $('code-input').focus();
}

function codeError(text) {
  $('code-error').textContent = text;
  $('code-error').hidden = false;
}

async function redeemCode() {
  const code = $('code-input').value.replace(/\D/g, '');
  if (redeeming) return;
  if (code.length !== 6) {
    codeError('Son 6 números');
    return;
  }
  redeeming = true;
  $('code-add').disabled = true;
  $('code-add').textContent = 'Buscando…';
  $('code-error').hidden = true;
  try {
    const res = await fetch('api/code', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ code }),
      cache: 'no-store',
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) {
      codeError(data.error || 'No pude revisar el código, intenta otra vez');
      return;
    }
    const payload = { id: data.id, token: data.token, name: String(data.name || 'Proyector').slice(0, 40) };
    if (!validProjector(payload)) {
      codeError('El proyector contestó algo raro: actualízalo');
      return;
    }
    $('code-input').blur();
    addProjector(payload);
  } catch {
    codeError('Sin conexión a internet');
  } finally {
    redeeming = false;
    $('code-add').disabled = false;
    $('code-add').textContent = 'Agregar';
  }
}

$('code-input').addEventListener('input', () => {
  const el = $('code-input');
  const digits = el.value.replace(/\D/g, '').slice(0, 6);
  if (el.value !== digits) el.value = digits;
  $('code-error').hidden = true;
  if (digits.length === 6) redeemCode();
});
$('code-form').addEventListener('submit', (e) => {
  e.preventDefault();
  redeemCode();
});
$('link-toggle').addEventListener('click', () => {
  $('link-toggle').hidden = true;
  $('link-box').hidden = false;
  $('paste-input').focus();
});
$('paste-add').addEventListener('click', () => addFromText($('paste-input').value));
$('paste-clipboard').addEventListener('click', async () => {
  try {
    $('paste-input').value = await navigator.clipboard.readText();
  } catch {
    toast('No pude leer el portapapeles: mantén presionado el cuadro y elige Pegar', { error: true });
  }
});

// ---------------------------------------------------------------------------
// QR scanner: camera + jsQR (Safari has no BarcodeDetector). jsQR is ~250 KB,
// so it loads only when the scanner opens.

let scanStream = null;
let scanLoop = 0;
let jsqrLoading = null;

function loadJsQR() {
  if (window.jsQR) return Promise.resolve();
  if (!jsqrLoading) {
    jsqrLoading = new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = 'vendor/jsQR.js';
      s.onload = resolve;
      s.onerror = () => { jsqrLoading = null; reject(new Error('jsQR')); };
      document.head.appendChild(s);
    });
  }
  return jsqrLoading;
}

async function openScanner() {
  closeSheets();
  if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
    toast('Este navegador no deja usar la cámara. Usa "Tengo un código".', { error: true });
    return;
  }
  $('scanner-text').textContent = 'Apunta la cámara al QR que muestra el proyector';
  $('scanner').hidden = false;
  try {
    const [stream] = await Promise.all([
      // Safari defaults to 640x480, too few pixels for a dense QR seen from
      // across the room. `ideal` never fails; the camera picks what it can.
      navigator.mediaDevices.getUserMedia({
        video: { facingMode: 'environment', width: { ideal: 1920 }, height: { ideal: 1080 } },
        audio: false,
      }),
      loadJsQR(),
    ]);
    if ($('scanner').hidden) {
      // Closed while waiting for the permission prompt.
      stream.getTracks().forEach((t) => t.stop());
      return;
    }
    scanStream = stream;
    const video = $('scanner-video');
    video.srcObject = stream;
    await video.play().catch(() => {});
    scanFrames(video);
  } catch (e) {
    closeScanner();
    toast(e && e.name === 'NotAllowedError'
      ? 'Sin permiso para la cámara. Actívalo en Ajustes o usa "Tengo un código".'
      : 'No pude abrir la cámara', { error: true });
  }
}

function scanFrames(video) {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  const frameEl = document.querySelector('.scanner-frame');
  let last = 0;
  let n = 0;
  const tick = (now) => {
    if (!scanStream) return;
    scanLoop = requestAnimationFrame(tick);
    // About five reads per second is plenty and keeps old phones cool.
    if (now - last < 200 || video.readyState < 2) return;
    last = now;
    const w = video.videoWidth;
    const h = video.videoHeight;
    if (!w || !h) return;
    // Most reads look only inside the on-screen frame, at the camera's full
    // resolution, so the QR keeps its detail. Every third read scans the whole
    // picture, in case the QR is outside the frame.
    const box = ++n % 3 === 0 ? { x: 0, y: 0, w, h } : frameBox(video, frameEl, w, h);
    const scale = Math.min(1, (box.w === w ? 640 : 800) / Math.max(box.w, box.h));
    canvas.width = Math.round(box.w * scale);
    canvas.height = Math.round(box.h * scale);
    ctx.drawImage(video, box.x, box.y, box.w, box.h, 0, 0, canvas.width, canvas.height);
    const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
    const code = window.jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
    if (!code || !code.data) return;
    try {
      const payload = parsePairing(code.data);
      closeScanner();
      addProjector(payload);
    } catch (e) {
      $('scanner-text').textContent = e.message;
    }
  };
  scanLoop = requestAnimationFrame(tick);
}

// The on-screen frame in video pixels. The video uses object-fit: cover and
// the frame sits in the middle of the screen, so it maps to a centered square.
function frameBox(video, frameEl, w, h) {
  const r = video.getBoundingClientRect();
  const f = frameEl.getBoundingClientRect();
  const s = Math.max(r.width / w, r.height / h) || 1;
  // A margin, so a QR that touches the border still reads.
  const side = Math.round(Math.min(w, h, (f.width * 1.3) / s));
  return { x: Math.round((w - side) / 2), y: Math.round((h - side) / 2), w: side, h: side };
}

function closeScanner() {
  cancelAnimationFrame(scanLoop);
  if (scanStream) scanStream.getTracks().forEach((t) => t.stop());
  scanStream = null;
  $('scanner-video').srcObject = null;
  $('scanner').hidden = true;
}

$('scanner-close').addEventListener('click', closeScanner);

// ---------------------------------------------------------------------------
// Polling: what the selected projector plays, its volume, and (less often) the
// other projectors' dots.

let refreshing = false;

async function refresh() {
  const p = current();
  if (!p) {
    render();
    return;
  }
  if (refreshing) return;
  refreshing = true;
  try {
    const r = await api(p, 'health');
    if (p !== current()) return;
    if (r.status === 200 && r.data.ok) {
      if (r.data.id && r.data.id !== p.id) status[p.id] = 'offline';
      health = r.data;
      // The projector owns its name.
      if (r.data.name && r.data.name !== p.name) {
        p.name = String(r.data.name).slice(0, 40);
        saveStore();
      }
      // Authenticated: proves the token and fills the slider.
      const v = await api(p, 'volume');
      if (p !== current()) return;
      if (v.status === 200 && v.data.ok) volume = v.data;
      if (status[p.id] === 'online' && store.phoneName && !announced.has(p.id)) {
        announced.add(p.id);
        api(p, 'pair', { method: 'POST', body: { phoneName: store.phoneName } });
      }
    } else if (r.status === 0) {
      // This phone is offline; keep showing the last known state.
    } else {
      if (r.status !== 401 && r.status !== 503) status[p.id] = 'offline';
      health = null;
      volume = null;
    }
    checked = true;
  } finally {
    refreshing = false;
  }
  render();
}

async function refreshOthers() {
  const sel = current();
  await Promise.all(store.projectors.filter((p) => p !== sel).map(async (p) => {
    const r = await api(p, 'health');
    if (r.status === 200 && r.data.id === p.id) {
      if (status[p.id] !== 'unauthorized') status[p.id] = 'online';
    } else if (r.status !== 0) {
      status[p.id] = 'offline';
    }
  }));
  if (!$('sheet-screens').hidden) renderScreens();
}

// ---------------------------------------------------------------------------
// Ahora: transport and volume.

function queueMode() {
  const q = (health && health.queue) || {};
  return !!(q.active && q.info);
}

async function media(action) {
  const p = current();
  if (!p) return;
  if (projectorMode() === 'spotify' && (action === 'toggle' || action === 'next' || action === 'stop')) {
    await spotifyMedia(p, action);
    return;
  }
  let r;
  if (action === 'next') {
    toast('Buscando la siguiente…');
    r = await api(p, 'queue', { method: 'POST', body: { next: true } });
    if (r.status === 200) {
      if (health) health.queue = { active: !!r.data.info, info: r.data.info || null };
      toast(r.data.info ? `Sonando en ${p.name}: ${r.data.info}` : 'Cola terminada');
    }
  } else if (action === 'back' || action === 'fwd') {
    r = await api(p, 'media', { method: 'POST', body: { action: 'seek', by: action === 'fwd' ? SEEK_S : -SEEK_S } });
  } else if (action === 'toggle') {
    const playing = health && health.media && health.media.playing;
    r = await api(p, 'media', { method: 'POST', body: { action: playing ? 'pause' : 'play' } });
    if (r.status === 200 && health && health.media) health.media.playing = !playing;
  } else {
    r = await api(p, 'media', { method: 'POST', body: { action } });
    if (action === 'stop' && r.status === 200) {
      delete store.lastSent[p.id];
      saveStore();
      if (health) {
        health.queue = { active: false, info: null };
        if (health.media) health.media.playing = false;
      }
      toast('Detenido');
    }
  }
  if (r.status === 409) toast('No hay video sonando en la pantalla', { error: true });
  else if (r.status !== 200) toast(errorText(r, p), { error: true });
  render();
  setTimeout(refresh, 900);
}

async function spotifyMedia(p, action) {
  const m = (health && health.media) || {};
  try {
    if (action === 'next') {
      await spotifyNext();
    } else if (action === 'toggle') {
      const wasPlaying = await spotifyToggle();
      if (stateOf(p) === 'online' && m.title) {
        await api(p, 'media', { method: 'POST', body: { action: wasPlaying ? 'pause' : 'play' } });
        m.playing = !wasPlaying;
      }
    } else {
      await spotifyPause();
      if (stateOf(p) === 'online' && (m.title || queueMode())) {
        await api(p, 'media', { method: 'POST', body: { action: 'stop' } });
        if (health) health.queue = { active: false, info: null };
        m.playing = false;
      }
      toast('Detenido');
    }
  } catch (e) {
    toast(e.message, { error: true });
  }
  render();
  setTimeout(refresh, 900);
}

async function setVolume(body) {
  const p = current();
  if (!p) return;
  const r = await api(p, 'volume', { method: 'POST', body });
  if (r.status === 200 && r.data.ok) volume = r.data;
  else toast(errorText(r, p), { error: true });
  renderVolume();
}

$('vol-range').addEventListener('input', () => {
  volDragging = true;
  paintVolume(Number($('vol-range').value));
});
// Sent only on release, like the app's slider.
$('vol-range').addEventListener('change', () => {
  volDragging = false;
  setVolume({ level: Number($('vol-range').value) });
});
$('btn-mute').addEventListener('click', () => setVolume({ mute: !(volume && volume.muted) }));

// ---------------------------------------------------------------------------
// Buscar: a screen over the tabs, with the assistant's microphone.

let searching = false;
let results = [];
let resultsFromAssistant = false;
let assistantOn = false;
let asking = false;
let recognizer = null;
// No SpeechRecognition: the keyboard's microphone types into the field, and
// the next submit goes to the assistant instead of a plain search.
let dictating = false;

// Screens pushed over the tabs (Buscar, a playlist's songs): a history entry
// each, so the phone's back gesture closes them like in the app.
function pushView(v) {
  if (view === v) return;
  if (view !== 'tabs') history.replaceState({ v }, '', `#${v}`);
  else history.pushState({ v }, '', `#${v}`);
  view = v;
  render();
}

function popView() {
  if (history.state && history.state.v === view) history.back();
  else {
    view = 'tabs';
    render();
  }
}

window.addEventListener('popstate', () => {
  const v = (history.state && history.state.v) || 'tabs';
  if (v === view) return;
  // A pushed view with nothing to show (e.g. after a reload) goes to the tabs.
  view = (v === 'tracks' && !openList) || (v === 'mask' && !mask) ? 'tabs' : v;
  stopListening();
  render();
});

function openSearch() {
  pushView('search');
  // Synchronously, inside the tap: iOS only raises the keyboard then.
  if (!results.length) $('search-input').focus();
}

$('btn-search').addEventListener('click', openSearch);
$('btn-back').addEventListener('click', popView);

$('search-input').addEventListener('input', () => {
  $('search-clear').hidden = !$('search-input').value || asking;
});
$('search-clear').addEventListener('click', () => {
  $('search-input').value = '';
  $('search-clear').hidden = true;
  $('search-input').focus();
});

$('search-form').addEventListener('submit', (e) => {
  e.preventDefault();
  const q = $('search-input').value.trim();
  if (!q) return;
  if (dictating) {
    dictating = false;
    ask(q);
  } else {
    search(q);
  }
});

async function search(q) {
  if (searching || asking) return;
  searching = true;
  resultsFromAssistant = false;
  $('search-input').blur();
  $('assist-line').hidden = true;
  $('search-progress').hidden = false;
  try {
    const res = await fetch(`api/search?q=${encodeURIComponent(q)}`, { cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) throw new Error(data.error || 'No pude buscar, intenta otra vez');
    results = data.results || [];
    if (!results.length) toast('No encontré nada con eso. Prueba con otras palabras.');
  } catch (err) {
    toast(err.message === 'Failed to fetch' ? 'Sin conexión a internet' : err.message, { error: true });
  } finally {
    searching = false;
    $('search-progress').hidden = true;
    renderSearch();
  }
}

async function play(video) {
  const p = current();
  if (!p) return;
  const r = await api(p, 'play', { method: 'POST', body: { videoId: video.id, title: video.title } });
  if (r.status !== 200 || !r.data.ok) {
    toast(errorText(r, p), { error: true });
    render();
    return false;
  }
  // The row and the Ahora card show what was sent, so no toast.
  store.lastSent[p.id] = { id: video.id, title: video.title, thumb: video.thumb || null, at: Date.now() };
  saveStore();
  renderSearch();
  setTimeout(refresh, 1500);
  return true;
}

// Voice assistant. The relay does the work (Claude + the projector calls), so
// the Anthropic key never reaches this page.

const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;

function assistLine(text, kind) {
  const el = $('assist-line');
  el.replaceChildren();
  if (kind === 'busy') {
    const s = document.createElement('span');
    s.className = 'spinner';
    el.append(s);
  } else if (kind === 'done') {
    el.insertAdjacentHTML('beforeend', '<svg><use href="#i-sparkle"/></svg>');
  }
  el.append(document.createTextNode(text));
  el.className = `assist-line${kind ? ` ${kind}` : ''}`;
  el.hidden = false;
}

async function ask(text) {
  const said = String(text || '').trim();
  const p = current();
  if (!said || !p || asking) return;
  asking = true;
  $('search-input').value = said;
  $('search-input').blur();
  $('search-input').disabled = true;
  $('assist-mic').disabled = true;
  $('search-clear').hidden = true;
  assistLine('Pensando…', 'busy');
  try {
    const res = await fetch('api/assistant', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        said,
        selected: p.id,
        projectors: store.projectors.map(({ id, token, name }) => ({ id, token, name })),
      }),
      cache: 'no-store',
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) {
      assistLine(data.error || 'No pude, intenta otra vez', 'error');
      return;
    }
    assistLine(data.reply || 'Listo', 'done');
    // "Ahora en la recámara": the assistant changed projector.
    if (data.selected && data.selected !== store.selected && store.projectors.some((x) => x.id === data.selected)) {
      select(data.selected);
    }
    const sel = current();
    if (data.played && sel) {
      const first = (data.results || []).find((v) => v.id === data.played.id);
      store.lastSent[sel.id] = { ...data.played, thumb: first ? first.thumb : null, at: Date.now() };
      saveStore();
    }
    if (Array.isArray(data.results) && data.results.length) {
      results = data.results;
      resultsFromAssistant = true;
    }
    volume = null;
    setTimeout(refresh, 1200);
  } catch {
    assistLine('Sin conexión a internet', 'error');
  } finally {
    asking = false;
    $('search-input').disabled = false;
    $('assist-mic').disabled = false;
    renderSearch();
  }
}

function stopListening() {
  if (recognizer) recognizer.abort();
}

function listen() {
  if (asking) return;
  if (recognizer) {
    recognizer.stop();
    return;
  }
  if (!Recognition) {
    dictating = true;
    $('search-input').value = '';
    $('search-input').focus();
    assistLine('Toca el micrófono del teclado, dime qué poner y luego Buscar');
    return;
  }
  const r = new Recognition();
  r.lang = 'es-MX';
  r.interimResults = true;
  r.continuous = false;
  let finalText = '';
  let failed = false;
  r.onresult = (e) => {
    let text = '';
    for (const res of e.results) {
      text += res[0].transcript;
      if (res.isFinal) finalText = text;
    }
    $('search-input').value = text;
  };
  r.onerror = (e) => {
    failed = true;
    if (e.error === 'not-allowed' || e.error === 'service-not-allowed') {
      dictating = true;
      assistLine('Sin permiso para el micrófono: usa el micrófono del teclado y luego Buscar', 'error');
      $('search-input').focus();
    } else if (e.error === 'no-speech') {
      assistLine('No te escuché, intenta otra vez');
    }
  };
  r.onend = () => {
    recognizer = null;
    setListening(false);
    const text = finalText || $('search-input').value;
    if (!failed && text.trim()) ask(text);
  };
  recognizer = r;
  $('search-input').value = '';
  setListening(true);
  try {
    r.start();
  } catch {
    recognizer = null;
    setListening(false);
    dictating = true;
    $('search-input').focus();
    assistLine('Toca el micrófono del teclado, dime qué poner y luego Buscar');
  }
}

function setListening(on) {
  $('assist-mic').classList.toggle('listening', on);
  $('icon-mic').toggleAttribute('hidden', on);
  $('icon-eq').toggleAttribute('hidden', !on);
  $('search-input').placeholder = on ? 'Te escucho…' : 'Canción o artista';
  if (on) $('assist-line').hidden = true;
}

$('assist-mic').addEventListener('click', listen);

// ---------------------------------------------------------------------------
// Screens: pick, rename, copy code, remove.

function select(id) {
  if (store.selected !== id) {
    health = null;
    volume = null;
    checked = false;
  }
  store.selected = id;
  saveStore();
  closeSheets();
  render();
  refresh();
}

function openScreens() {
  renderScreens();
  openSheet('sheet-screens');
  checkVersion();
  refreshOthers();
}

let menuFor = null;

function openMenu(p) {
  menuFor = p;
  $('menu-title').textContent = p.name;
  const items = $('menu-items');
  items.replaceChildren();
  const add = (label, fn, danger = false) => {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = label;
    if (danger) b.className = 'danger';
    b.addEventListener('click', fn);
    items.append(b);
  };
  add('Renombrar', () => {
    $('rename-input').value = p.name;
    openSheet('sheet-rename');
    $('rename-input').focus();
  });
  add('Máscara de proyección', () => openMask(p));
  if (p === current() && screenLinked()) add('Desvincular Spotify del proyector', () => unlinkSpotifyFromScreen(p));
  add('Copiar código (para otro teléfono)', () => copyCode(p));
  add('Eliminar', () => {
    $('confirm-title').textContent = `¿Eliminar ${p.name}?`;
    $('confirm-text').textContent = 'El proyector deja de seguir a Spotify y se corta su cola. Para volver a usarlo hay que escanear su QR.';
    openSheet('sheet-confirm');
  }, true);
  openSheet('sheet-menu');
}

$('rename-save').addEventListener('click', async () => {
  const p = menuFor;
  const name = $('rename-input').value.trim().slice(0, 40);
  if (!p || !name) {
    $('rename-input').focus();
    return;
  }
  closeSheets();
  // The projector owns its name: rename it there when it answers.
  if (stateOf(p) === 'online') {
    const r = await api(p, 'pair', {
      method: 'POST',
      body: { phoneName: store.phoneName || defaultPhoneName(), screenName: name },
    });
    if (r.status === 200 && r.data.ok) p.name = String(r.data.name || name).slice(0, 40);
    else {
      toast(errorText(r, p), { error: true });
      p.name = name;
    }
  } else {
    p.name = name;
  }
  saveStore();
  render();
});

async function copyCode(p) {
  closeSheets();
  const link = pairingLink(p);
  if (navigator.share) {
    try {
      await navigator.share({ title: 'Proyector', text: `Para controlar ${p.name}`, url: link });
      return;
    } catch (e) {
      if (e && e.name === 'AbortError') return;
    }
  }
  try {
    await navigator.clipboard.writeText(link);
    toast('Código copiado: mándalo por WhatsApp; al abrirlo en el otro teléfono se agrega solo');
  } catch {
    toast('No pude copiar el código', { error: true });
  }
}

$('confirm-ok').addEventListener('click', () => {
  if (menuFor) removeProjector(menuFor);
});

async function removeProjector(p) {
  closeSheets();
  // The projector stops following Spotify, cuts its queue and forgets this
  // phone. At most 4 s: a projector that is off must not block the removal.
  const calls = [
    api(p, 'spotify', { method: 'POST', body: { unlink: true } }).then((r) => r.status === 200),
    api(p, 'queue', { method: 'POST', body: { stop: true } }).then((r) => r.status === 200),
  ];
  if (store.phoneName) {
    calls.push(api(p, 'unpair', { method: 'POST', body: { phoneName: store.phoneName } }).then(() => true));
  }
  const reached = await Promise.race([
    Promise.all(calls).then((all) => all.every(Boolean)),
    new Promise((resolve) => setTimeout(() => resolve(false), 4000)),
  ]);
  store.projectors = store.projectors.filter((x) => x.id !== p.id);
  delete store.lastSent[p.id];
  delete status[p.id];
  if (store.selected === p.id) {
    store.selected = store.projectors[0] ? store.projectors[0].id : null;
    health = null;
    volume = null;
    checked = false;
  }
  saveStore();
  toast(reached
    ? `${p.name} desvinculada: para volver a usarla escanea su QR`
    : `Borré ${p.name}, pero no respondió: si seguía a Spotify, lo sigue. Apágalo en el proyector con "Dejar de seguir a Spotify" o, cuando prenda, escanea su QR y elimínalo otra vez`);
  render();
  refresh();
}

// ---------------------------------------------------------------------------
// Taps.

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-media],[data-action],[data-tab]');
  if (!el) return;
  if (el.dataset.media) media(el.dataset.media);
  else if (el.dataset.tab) setTab(el.dataset.tab);
  else if (el.dataset.action === 'scan') openScanner();
  else if (el.dataset.action === 'paste') openCodeSheet();
  else if (el.dataset.action === 'rename-phone') askPhoneName(null);
  else if (el.dataset.action === 'search') openSearch();
  else if (el.dataset.action === 'close') closeSheets();
  else if (el.dataset.action === 'spotify-login') spotifyAuthorize('phone');
});

$('spotify-connect').addEventListener('click', () => spotifyAuthorize('phone'));
$('btn-send').addEventListener('click', () => sendTrack(track));
$('btn-link-spotify').addEventListener('click', () => {
  const p = current();
  if (p) spotifyAuthorize(`link:${p.id}`);
});
$('chip-follow').addEventListener('click', () => {
  if (screenLinked()) setScreenFollowing(!followingSpotify());
  else setAutoFollow(!store.autoFollow);
});
$('chip-others').addEventListener('click', openOthers);
$('spotify-row-btn').addEventListener('click', () => {
  if (spotifyLoggedIn()) spotifyLogout();
  else spotifyAuthorize('phone');
});

/// The other videos YouTube found for the song that was sent.
function openOthers() {
  const p = current();
  const list = $('others-list');
  list.replaceChildren();
  for (const v of candidates.slice(1)) {
    const li = document.createElement('li');
    li.append(resultRow(v, p, false, () => {
      closeSheets();
      play(v);
    }));
    list.append(li);
  }
  openSheet('sheet-others');
}

$('screen-pick').addEventListener('click', openScreens);
$('btn-add').addEventListener('click', () => {
  renderAddSheet();
  openSheet('sheet-add');
});

// ---------------------------------------------------------------------------
// Rendering.

function setTab(name) {
  tab = name;
  for (const b of document.querySelectorAll('[data-tab]')) b.classList.toggle('on', b.dataset.tab === name);
  render();
  if (name === 'playlists') loadPlaylists();
}

function render() {
  const p = current();
  const pushed = !!p && view !== 'tabs';
  const inSearch = pushed && view === 'search';
  $('top').hidden = !p;
  $('top').classList.toggle('in-search', pushed);
  $('btn-back').hidden = !pushed;
  $('btn-search').hidden = inSearch;
  $('tabs').hidden = !p || pushed;
  document.body.classList.toggle('no-tabs', !p || pushed);
  $('view-welcome').hidden = !!p;
  $('view-now').hidden = !p || pushed || tab !== 'now';
  $('view-playlists').hidden = !p || pushed || tab !== 'playlists';
  $('view-search').hidden = !inSearch;
  $('view-tracks').hidden = !(pushed && view === 'tracks');
  $('view-mask').hidden = !(pushed && view === 'mask');
  $('playlists-login').hidden = spotifyLoggedIn();
  $('playlists-body').hidden = !spotifyLoggedIn();
  if (!p) return;
  renderHeader(p);
  renderNow(p);
  if (inSearch) renderSearch();
  if (!pushed && tab === 'playlists') renderPlaylists();
  if (pushed && view === 'tracks') renderTracks();
  if (pushed && view === 'mask') renderMask();
}

function renderHeader(p) {
  const st = stateOf(p);
  $('screen-name').textContent = p.name;
  $('screen-dot').className = `dot big${st === 'online' ? ' on' : ''}`;
  // Only when something is wrong: online is already the green dot.
  const problem = !checked ? 'revisando…'
    : st === 'unauthorized' ? 'el código cambió'
      : st === 'online' ? '' : 'sin respuesta';
  $('screen-problem').textContent = problem;
  $('screen-problem').hidden = !problem;
}

function renderNow(p) {
  const st = stateOf(p);
  const online = st === 'online';
  const m = (health && health.media) || {};
  const q = (health && health.queue) || {};
  const mode = projectorMode();
  const logged = spotifyLoggedIn();

  $('now-offline').hidden = !checked || online;
  $('offline-rescan').hidden = st !== 'unauthorized';
  $('offline-text').textContent = st === 'unauthorized'
    ? `El código de ${p.name} cambió. En el proyector abre "Vincular teléfono" y escanea el QR otra vez.`
    : `${p.name} no responde. Revisa que esté prendido y con internet; esto se actualiza solo.`;

  $('spotify-connect').hidden = !spotifyClientId || logged;
  $('spotify-connect').disabled = spotifyBusy;

  const empty = mode === 'free' && (!online || !m.title);
  $('now-empty').hidden = !empty;
  $('now-playing').hidden = empty;
  $('empty-text').textContent = `Pon música en Spotify y ${p.name} cambia el video sola, o busca un video para mandarlo.`;

  if (!empty) {
    const sent = store.lastSent[p.id];
    const sentThumb = sent ? sent.thumb || `https://i.ytimg.com/vi/${encodeURIComponent(sent.id)}/hqdefault.jpg` : '';
    // The projector reports the playing title, not the video id; reuse the
    // thumbnail of what this phone sent when it is what plays.
    let thumb = '';
    if (mode === 'spotify') thumb = sent && sentKey === trackKey(track) ? sentThumb : '';
    else if (mode === 'free') thumb = sent && m.title && sameTitle(m.title, sent.title) ? sentThumb : '';
    const albumArt = mode === 'spotify' && track ? track.artUrl : '';
    paintHero(thumb, albumArt, mode === 'queue');

    const showing = showingTrack();
    const sendable = mode === 'spotify' && logged && !!track && !showing && online;
    $('hero-send').hidden = !sendable;
    $('hero-send-text').textContent = `No está en ${p.name}`;
    $('btn-send').disabled = spotifyBusy;
    $('btn-send').querySelector('span').textContent = spotifyBusy ? 'Buscando…' : 'Enviar el video';

    const live = mode === 'spotify' ? showing : !!m.title;
    const chip = $('hero-chip');
    chip.hidden = !online || sendable;
    chip.className = `live-chip on-hero${live ? ' on with-icon' : ''}`;
    chip.querySelector('svg').toggleAttribute('hidden', !live);
    $('hero-chip-text').textContent = live ? `Reproduciéndose en ${p.name}`
      : mode === 'spotify' && followingSpotify() ? 'Esperando canción' : `No en ${p.name}`;

    if (mode === 'queue') {
      $('now-title').textContent = m.title || 'Buscando el video…';
      $('now-sub').textContent = q.info || '';
    } else if (mode === 'spotify') {
      $('now-title').textContent = track.title;
      $('now-sub').textContent = track.artists.join(', ');
    } else {
      $('now-title').textContent = m.title || 'Nada sonando';
      $('now-sub').textContent = `En ${p.name}`;
    }
  }

  // Transport: Detener · −10 · Play/Pausa · +10 · Siguiente.
  $('transport').classList.toggle('dimmed', empty);
  const video = online && !!m.title;
  const playing = mode === 'spotify' ? !!(track && track.isPlaying) : !!m.playing;
  for (const b of document.querySelectorAll('#transport [data-media]')) {
    const a = b.dataset.media;
    let ok;
    if (a === 'stop') ok = mode !== 'free' || video;
    else if (a === 'toggle') ok = mode === 'spotify' || video;
    else if (a === 'next') ok = mode !== 'free';
    else ok = video;
    b.disabled = !ok || spotifyBusy;
  }
  $('icon-play').toggleAttribute('hidden', playing);
  $('icon-pause').toggleAttribute('hidden', !playing);
  $('btn-toggle').setAttribute('aria-label', playing ? 'Pausar' : 'Reanudar');

  $('volume').hidden = !(online && volume);
  renderVolume();

  // Chips: "Seguir a Spotify" and "Otro video (n)".
  const canFollow = logged && checked;
  const own = screenLinked();
  const following = own ? !!(health.spotify && health.spotify.following) : store.autoFollow;
  const others = empty ? 0 : candidates.length - 1;
  $('chips').hidden = !canFollow && others <= 0;
  $('chip-follow').hidden = !canFollow;
  $('chip-follow').classList.toggle('on', following);
  $('chip-follow-label').textContent = following ? 'Siguiendo Spotify' : 'Seguir a Spotify';
  $('chip-follow-detail').hidden = own;
  $('chip-others').hidden = others <= 0;
  $('chip-others-label').textContent = `Otro video (${others})`;
  $('btn-link-spotify').hidden = !(canFollow && !own && online);
}

function paintHero(thumb, albumArt, queue) {
  const art = $('hero-art');
  const want = thumb ? `t:${thumb}` : albumArt ? `a:${albumArt}` : `p:${queue}`;
  if (art.dataset.want === want) return;
  art.dataset.want = want;
  art.replaceChildren();
  if (thumb) {
    const img = document.createElement('img');
    img.alt = '';
    img.src = thumb;
    img.onerror = () => {
      art.dataset.want = '';
      art.replaceChildren(placeholder(queue));
    };
    art.append(img);
  } else if (albumArt) {
    // The album art blurred behind, and square in the middle.
    const blur = document.createElement('img');
    blur.className = 'blur';
    blur.alt = '';
    blur.src = albumArt;
    const shade = document.createElement('div');
    shade.className = 'shade';
    const square = document.createElement('img');
    square.className = 'square';
    square.alt = '';
    square.src = albumArt;
    // If the art does not load, the plain placeholder instead of a broken image.
    square.onerror = () => art.replaceChildren(placeholder(queue));
    art.append(blur, shade, square);
  } else {
    art.append(placeholder(queue));
  }
}

function placeholder(queue) {
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('class', 'ph');
  const use = document.createElementNS(ns, 'use');
  use.setAttribute('href', queue ? '#i-queue-music' : '#i-display');
  svg.append(use);
  return svg;
}

function sameTitle(a, b) {
  const norm = (s) => String(s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
  const x = norm(a);
  const y = norm(b);
  return !!x && !!y && (x.includes(y) || y.includes(x));
}

function paintVolume(level) {
  const max = (volume && volume.max) || 15;
  $('vol-range').style.setProperty('--fill', `${(level / max) * 100}%`);
  $('vol-level').textContent = volume && volume.muted ? '—' : String(level);
}

function renderVolume() {
  const v = volume;
  if (!v) return;
  const range = $('vol-range');
  range.max = String(v.max || 15);
  if (!volDragging) range.value = String(v.level);
  paintVolume(volDragging ? Number(range.value) : v.level);
  $('icon-vol').querySelector('use').setAttribute('href', v.muted ? '#i-vol-off' : '#i-vol-mute');
  $('btn-mute').setAttribute('aria-label', v.muted ? 'Quitar silencio' : 'Silenciar');
}

function renderSearch() {
  const p = current();
  if (!p) return;
  $('assist-mic').hidden = !assistantOn;
  $('search-empty').hidden = results.length > 0 || searching;
  $('search-empty').textContent = assistantOn
    ? `Escribe una canción y elige el video, o toca el micrófono y pide algo: "música para la playa". Va a ${p.name}.`
    : `Escribe qué quieres ver y toca un resultado para mandarlo a ${p.name}.`;
  const sent = store.lastSent[p.id];
  const enabled = stateOf(p) !== 'offline' && stateOf(p) !== 'unauthorized' && !asking;
  const list = $('results');
  list.replaceChildren();
  results.forEach((v, i) => {
    if (resultsFromAssistant && i === 1) {
      const label = document.createElement('li');
      label.className = 'label-row';
      label.innerHTML = '<span class="section-label">¿No es el video correcto?</span>';
      list.append(label);
    }
    const li = document.createElement('li');
    const btn = resultRow(v, p, !!sent && sent.id === v.id, () => play(v));
    btn.disabled = !enabled;
    li.append(btn);
    list.append(li);
  });
}

function resultRow(v, p, isSent, onClick) {
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.className = `result${isSent ? ' sent' : ''}`;

  const thumb = document.createElement('div');
  thumb.className = 'thumb';
  const img = document.createElement('img');
  img.loading = 'lazy';
  img.alt = '';
  img.src = `https://i.ytimg.com/vi/${encodeURIComponent(v.id)}/mqdefault.jpg`;
  thumb.append(img);

  const meta = document.createElement('div');
  meta.className = 'meta';
  const t = document.createElement('div');
  t.className = 'title';
  t.textContent = v.title;
  meta.append(t);
  if (isSent && p) {
    const chip = document.createElement('span');
    chip.className = 'live-chip on';
    chip.textContent = `En ${p.name}`;
    meta.append(chip);
  } else {
    const d = document.createElement('div');
    d.className = 'details';
    d.textContent = [v.channel, v.duration].filter(Boolean).join(' · ');
    meta.append(d);
  }
  btn.append(thumb, meta);
  btn.addEventListener('click', onClick);
  return btn;
}

function renderScreens() {
  const list = $('screens-list');
  list.replaceChildren();
  if (!store.projectors.length) {
    const li = document.createElement('li');
    li.className = 'empty-devices';
    li.textContent = 'Todavía no hay pantallas. Agrega una con el + junto al nombre.';
    list.append(li);
  }
  const sel = current();
  for (const p of store.projectors) {
    const st = stateOf(p);
    const li = document.createElement('li');
    li.className = `device${sel && sel.id === p.id ? ' selected' : ''}${st === 'online' ? ' online' : ''}`;

    const pick = document.createElement('button');
    pick.type = 'button';
    pick.className = 'pick';
    pick.insertAdjacentHTML('beforeend', '<svg><use href="#i-videocam"/></svg>');
    const names = document.createElement('span');
    names.className = 'names';
    const b = document.createElement('b');
    b.textContent = p.name;
    const small = document.createElement('small');
    small.textContent = 'Proyector';
    names.append(b, small);
    pick.append(names);
    pick.addEventListener('click', () => select(p.id));

    const chip = document.createElement('span');
    chip.className = `live-chip${st === 'online' ? ' on' : ''}`;
    chip.textContent = st === 'online' ? 'En línea'
      : st === 'unauthorized' ? 'Código cambiado'
        : st === 'unknown' ? 'Revisando…' : 'Sin respuesta';

    const more = document.createElement('button');
    more.type = 'button';
    more.className = 'icon-btn';
    more.setAttribute('aria-label', `Opciones de ${p.name}`);
    more.insertAdjacentHTML('beforeend', '<svg><use href="#i-more"/></svg>');
    more.addEventListener('click', () => openMenu(p));

    li.append(pick, chip, more);
    list.append(li);
  }
}

function renderAddSheet() {
  $('phone-name-label').textContent = store.phoneName || 'Sin nombre';
  $('spotify-row').hidden = !spotifyClientId;
  $('spotify-row-label').textContent = spotifyLoggedIn() ? 'Spotify conectado' : 'Spotify sin conectar';
  $('spotify-row-btn').textContent = spotifyLoggedIn() ? 'Cerrar sesión' : 'Conectar';
}

// ---------------------------------------------------------------------------
// Version. The relay writes it into the page and loads app.js with ?v=, so
// this is the code that is running. If the server has a newer one (a home
// screen app on iOS can keep an old page for a long time), say so.

const metaVersion = document.querySelector('meta[name="app-version"]');
const APP_VERSION = metaVersion && !metaVersion.content.includes('__') ? metaVersion.content : 'dev';
let serverVersion = null;

function renderVersion() {
  const el = $('app-ver');
  const stale = serverVersion && APP_VERSION !== 'dev' && serverVersion !== APP_VERSION;
  el.classList.toggle('stale', !!stale);
  el.textContent = stale ? 'Nueva versión · tocar' : `versión ${APP_VERSION}`;
  $('version').textContent = stale
    ? `versión ${APP_VERSION} (hay una nueva: ${serverVersion})`
    : `versión ${APP_VERSION}`;
}

async function checkVersion() {
  try {
    const v = await (await fetch('version.json', { cache: 'no-store' })).json();
    if (typeof v.version === 'string') serverVersion = v.version;
    if (typeof v.assistant === 'boolean' && v.assistant !== assistantOn) {
      assistantOn = v.assistant;
      renderSearch();
    }
  } catch {
    // Offline: keep what we knew.
  }
  renderVersion();
}

$('app-ver').addEventListener('click', () => {
  if ($('app-ver').classList.contains('stale')) location.reload();
  else toast(`Versión ${APP_VERSION}`);
});

// ---------------------------------------------------------------------------
// Polling every 3 s while the page is visible, like the app; the other
// projectors' dots every 4th time.

setInterval(() => {
  if (document.visibilityState !== 'visible') return;
  if (spotifyLoggedIn()) pollSpotify();
  if (!current()) return;
  refresh();
  if (++ticks % 4 === 0) refreshOthers();
}, POLL_MS);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') {
    refresh();
    checkVersion();
    if (spotifyLoggedIn()) pollSpotify();
  }
});

// A pairing link in the address (#pair?v=1&id=…): the projector's QR opened
// with the phone's camera.
if (location.hash.startsWith('#pair?')) {
  const text = location.hash;
  history.replaceState(null, '', location.pathname);
  addFromText(text);
} else if (['#search', '#tracks', '#mask'].includes(location.hash)) {
  history.replaceState(null, '', location.pathname);
}

render();
refresh();
renderVersion();
checkVersion();
spotifyCallback().then((wasCallback) => {
  if (!wasCallback && spotifyLoggedIn()) {
    // A token from before a new permission was added: connect again.
    const have = String(spToken.scope || '').split(' ');
    if (!SPOTIFY_SCOPES.every((sc) => have.includes(sc))) {
      dropSpotify();
      toast('Spotify pide un permiso nuevo (saltar y pausar): vuelve a conectar');
    } else {
      pollSpotify();
    }
  }
  render();
});
