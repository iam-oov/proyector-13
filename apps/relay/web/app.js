'use strict';

// Projector control PWA served by the relay at www.valdoh.com/proyector.
// Every call goes through the relay (api/p/<id>/<path>), which hands it to
// the projector over its WebSocket. The projector checks the QR's Bearer token
// itself; this page only stores it. UI strings are Spanish.

const $ = (id) => document.getElementById(id);
const POLL_MS = 4000;
const SEEK_S = 10;

// ---------------------------------------------------------------------------
// Storage. localStorage may throw (private mode) or come back empty; the app
// must still work for this visit.

const STORE_KEY = 'proyector.v1';

function loadStore() {
  try {
    const raw = localStorage.getItem(STORE_KEY);
    const data = raw ? JSON.parse(raw) : {};
    return {
      projectors: Array.isArray(data.projectors) ? data.projectors.filter(validProjector) : [],
      selected: typeof data.selected === 'string' ? data.selected : null,
      phoneName: typeof data.phoneName === 'string' ? data.phoneName : '',
      lastSent: data.lastSent && typeof data.lastSent === 'object' ? data.lastSent : {},
    };
  } catch {
    return { projectors: [], selected: null, phoneName: '', lastSent: {} };
  }
}

function saveStore() {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify(store));
  } catch {
    // Not persisted; nothing else to do.
  }
}

const ID_RE = /^[a-z0-9]{8,32}$/;
const TOKEN_RE = /^[A-Za-z0-9_-]{16,128}$/;

function validProjector(p) {
  return p && ID_RE.test(p.id) && TOKEN_RE.test(p.token) && typeof p.name === 'string';
}

const store = loadStore();

// Live state per projector id: 'unknown' | 'online' | 'offline' | 'unauthorized'.
const status = {};
let health = null;
let volume = null;
let tab = 'now';

function current() {
  return store.projectors.find((p) => p.id === store.selected) || store.projectors[0] || null;
}

// ---------------------------------------------------------------------------
// Pairing payload: the projector's QR says
//   proyector://pair?v=1&id=<id>&n=<name>&h=<lan host>&p=<port>&t=<token>
// The LAN host and port are ignored: this page always goes through the relay.

function parsePairing(raw) {
  const text = String(raw || '').trim();
  const q = text.indexOf('?');
  if (!/^proyector:\/\/pair\?/i.test(text) && !text.startsWith('#pair?') && !text.startsWith('pair?')) {
    throw new Error('Ese código no es de un proyector');
  }
  const params = new URLSearchParams(text.slice(q + 1));
  const v = Number(params.get('v'));
  if (!v || v > 1) throw new Error('Código de una versión nueva: actualiza el proyector');
  const id = params.get('id') || '';
  const token = params.get('t') || '';
  if (!ID_RE.test(id) || !TOKEN_RE.test(token)) throw new Error('El código está incompleto');
  const name = (params.get('n') || 'Proyector').trim().slice(0, 40) || 'Proyector';
  return { id, token, name };
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
// Toast.

let toastTimer = 0;
function toast(text, { error = false } = {}) {
  const el = $('toast');
  el.textContent = text;
  el.classList.toggle('error', error);
  el.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { el.hidden = true; }, error ? 4500 : 2500);
}

// ---------------------------------------------------------------------------
// Sheets.

const sheets = ['sheet-screens', 'sheet-paste', 'sheet-phone'];
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

function askPhoneName(then) {
  $('phone-input').value = store.phoneName || defaultPhoneName();
  openSheet('sheet-phone');
  afterPhoneName = then;
  setTimeout(() => $('phone-input').focus(), 50);
}

function defaultPhoneName() {
  const ua = navigator.userAgent;
  if (/iPhone/.test(ua)) return 'iPhone';
  if (/iPad/.test(ua)) return 'iPad';
  if (/Android/.test(ua)) return 'Android';
  return 'Teléfono';
}

$('phone-save').addEventListener('click', () => {
  const name = $('phone-input').value.trim().slice(0, 40);
  if (!name) {
    $('phone-input').focus();
    return;
  }
  store.phoneName = name;
  saveStore();
  const then = afterPhoneName;
  closeSheets();
  renderScreens();
  if (then) then();
});

$('scrim').addEventListener('click', closeSheets);

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
  const entry = { id: payload.id, token: payload.token, name: String(r.data.name || payload.name).slice(0, 40) };
  const at = store.projectors.findIndex((p) => p.id === entry.id);
  if (at >= 0) store.projectors[at] = entry;
  else store.projectors.push(entry);
  store.selected = entry.id;
  status[entry.id] = 'online';
  saveStore();
  closeSheets();
  toast(`${entry.name} agregado`);
  setTab('now');
  render();
  refresh();
}

function addFromText(text) {
  try {
    addProjector(parsePairing(text));
  } catch (e) {
    toast(e.message, { error: true });
  }
}

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
  $('scanner-text').textContent = 'Apunta al código QR del proyector';
  $('scanner').hidden = false;
  try {
    const [stream] = await Promise.all([
      navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' }, audio: false }),
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
  let last = 0;
  const tick = (now) => {
    if (!scanStream) return;
    scanLoop = requestAnimationFrame(tick);
    // About five reads per second is plenty and keeps old phones cool.
    if (now - last < 200 || video.readyState < 2) return;
    last = now;
    const w = video.videoWidth;
    const h = video.videoHeight;
    if (!w || !h) return;
    const scale = Math.min(1, 640 / Math.max(w, h));
    canvas.width = Math.round(w * scale);
    canvas.height = Math.round(h * scale);
    ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
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

function closeScanner() {
  cancelAnimationFrame(scanLoop);
  if (scanStream) scanStream.getTracks().forEach((t) => t.stop());
  scanStream = null;
  $('scanner-video').srcObject = null;
  $('scanner').hidden = true;
}

$('scanner-close').addEventListener('click', closeScanner);

// ---------------------------------------------------------------------------
// Ahora: what the projector is playing, transport and volume.

async function refresh() {
  const p = current();
  if (!p) return;
  const r = await api(p, 'health');
  if (p !== current()) return;
  if (r.status === 200 && r.data.ok) {
    if (status[p.id] !== 'unauthorized') status[p.id] = 'online';
    health = r.data;
    // The projector's name can change on the projector itself.
    if (r.data.name && r.data.name !== p.name) {
      p.name = String(r.data.name).slice(0, 40);
      saveStore();
    }
    if (volume === null) refreshVolume();
  } else if (r.status === 0) {
    // This phone is offline; keep showing the last known state.
  } else {
    if (r.status !== 401 && r.status !== 503) status[p.id] = 'offline';
    health = null;
  }
  render();
}

async function refreshVolume() {
  const p = current();
  if (!p) return;
  // Also the first authenticated call after opening: a 401 here shows the
  // "code changed" notice before the user taps anything.
  const r = await api(p, 'volume');
  if (p !== current()) return;
  if (r.status === 200 && r.data.ok) volume = r.data;
  render();
}

async function media(action) {
  const p = current();
  if (!p) return;
  let r;
  if (action === 'next') r = await api(p, 'queue', { method: 'POST', body: { next: true } });
  else if (action === 'back') r = await api(p, 'media', { method: 'POST', body: { action: 'seek', by: -SEEK_S } });
  else if (action === 'fwd') r = await api(p, 'media', { method: 'POST', body: { action: 'seek', by: SEEK_S } });
  else if (action === 'toggle') {
    const playing = health && health.media && health.media.playing;
    r = await api(p, 'media', { method: 'POST', body: { action: playing ? 'pause' : 'play' } });
    if (r.status === 200 && health && health.media) health.media.playing = !playing;
  } else r = await api(p, 'media', { method: 'POST', body: { action } });

  if (r.status === 409) toast('No hay un video sonando', { error: true });
  else if (r.status !== 200) toast(errorText(r, p), { error: true });
  if (action === 'stop' && r.status === 200) {
    delete store.lastSent[p.id];
    saveStore();
  }
  render();
  setTimeout(refresh, 900);
}

async function changeVolume(kind) {
  const p = current();
  if (!p) return;
  const body = kind === 'mute' ? { mute: !(volume && volume.muted) } : { delta: kind === 'up' ? 1 : -1 };
  const r = await api(p, 'volume', { method: 'POST', body });
  if (r.status === 200 && r.data.ok) volume = r.data;
  else toast(errorText(r, p), { error: true });
  renderVolume();
}

document.addEventListener('click', (e) => {
  const el = e.target.closest('[data-media],[data-volume],[data-action],[data-tab]');
  if (!el) return;
  if (el.dataset.media) media(el.dataset.media);
  else if (el.dataset.volume) changeVolume(el.dataset.volume);
  else if (el.dataset.tab) setTab(el.dataset.tab);
  else if (el.dataset.action === 'scan') openScanner();
  else if (el.dataset.action === 'paste') {
    $('paste-input').value = '';
    openSheet('sheet-paste');
  } else if (el.dataset.action === 'rename-phone') askPhoneName(null);
});

// ---------------------------------------------------------------------------
// Buscar.

let searching = false;

$('search-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const q = $('search-input').value.trim();
  if (!q || searching) return;
  searching = true;
  $('search-input').blur();
  $('search-hint').textContent = 'Buscando…';
  $('results').replaceChildren();
  try {
    const res = await fetch(`api/search?q=${encodeURIComponent(q)}`, { cache: 'no-store' });
    const data = await res.json().catch(() => ({}));
    if (!res.ok || !data.ok) throw new Error(data.error || 'No pude buscar, intenta otra vez');
    renderResults(data.results || []);
    $('search-hint').textContent = data.results && data.results.length
      ? 'Toca un resultado para ponerlo en el proyector.'
      : 'No encontré nada con eso. Prueba con otras palabras.';
  } catch (err) {
    $('search-hint').textContent = err.message === 'Failed to fetch' ? 'Sin conexión a internet' : err.message;
  } finally {
    searching = false;
  }
});

function renderResults(results) {
  const list = $('results');
  list.replaceChildren();
  for (const v of results) {
    const li = document.createElement('li');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'result';

    const thumb = document.createElement('div');
    thumb.className = 'thumb';
    const img = document.createElement('img');
    img.loading = 'lazy';
    img.alt = '';
    img.src = `https://i.ytimg.com/vi/${encodeURIComponent(v.id)}/mqdefault.jpg`;
    thumb.append(img);
    if (v.duration) {
      const d = document.createElement('span');
      d.className = 'dur';
      d.textContent = v.duration;
      thumb.append(d);
    }

    const meta = document.createElement('div');
    meta.className = 'meta';
    const t = document.createElement('div');
    t.className = 'title';
    t.textContent = v.title;
    const c = document.createElement('div');
    c.className = 'channel';
    c.textContent = v.channel || '';
    meta.append(t, c);

    btn.append(thumb, meta);
    btn.addEventListener('click', () => play(v, btn));
    li.append(btn);
    list.append(li);
  }
}

async function play(video, btn) {
  const p = current();
  if (!p) return;
  btn.disabled = true;
  const r = await api(p, 'play', { method: 'POST', body: { videoId: video.id, title: video.title } });
  btn.disabled = false;
  if (r.status !== 200 || !r.data.ok) {
    toast(errorText(r, p), { error: true });
    render();
    return;
  }
  for (const el of document.querySelectorAll('.result.sent')) el.classList.remove('sent');
  btn.classList.add('sent');
  store.lastSent[p.id] = { id: video.id, title: video.title, at: Date.now() };
  saveStore();
  toast(`Listo, sonando en ${p.name}`);
  setTimeout(refresh, 1500);
}

// ---------------------------------------------------------------------------
// Rendering.

function setTab(name) {
  tab = name;
  for (const b of document.querySelectorAll('[data-tab]')) b.classList.toggle('on', b.dataset.tab === name);
  render();
  if (name === 'search' && !$('results').children.length) setTimeout(() => $('search-input').focus(), 50);
  if (name === 'now') refresh();
}

function render() {
  const p = current();
  $('tabs').hidden = !p;
  $('screen-chip').hidden = !p;
  $('view-welcome').hidden = !!p;
  $('view-now').hidden = !p || tab !== 'now';
  $('view-search').hidden = !p || tab !== 'search';
  if (!p) return;

  const st = status[p.id] || 'unknown';
  $('screen-name').textContent = p.name;
  $('screen-dot').className = `dot ${st === 'online' ? 'on' : st === 'unknown' ? '' : 'off'}`;
  renderNow(p, st);
}

function renderNow(p, st) {
  const ok = st === 'online' || st === 'unknown';
  $('now-offline').hidden = ok;
  $('offline-rescan').hidden = st !== 'unauthorized';
  if (st === 'unauthorized') {
    $('offline-title').textContent = `El código de ${p.name} cambió`;
    $('offline-text').textContent = 'Alguien generó un código nuevo en el proyector. Abre "Vincular teléfono" en el proyector y escanea el QR otra vez.';
  } else {
    $('offline-title').textContent = `${p.name} no está conectado`;
    $('offline-text').textContent = 'Revisa que esté prendido y con internet. Esto se actualiza solo.';
  }
  for (const el of document.querySelectorAll('#view-now .now, #view-now .volume')) el.style.opacity = ok ? '' : '.45';

  const m = (health && health.media) || {};
  const q = (health && health.queue) || {};
  const sent = store.lastSent[p.id];
  // The projector reports the playing title, not the video id; reuse the
  // thumbnail of what this phone sent last when the titles match.
  const title = m.title || (sent && sent.title) || '';
  const art = $('now-art');
  const showSent = sent && (!m.title || sameTitle(m.title, sent.title));
  const want = showSent ? `https://i.ytimg.com/vi/${encodeURIComponent(sent.id)}/hqdefault.jpg` : '';
  const img = art.querySelector('img');
  if (want && (!img || img.dataset.src !== want)) {
    const el = document.createElement('img');
    el.alt = '';
    el.src = want;
    el.dataset.src = want;
    art.replaceChildren(el);
  } else if (!want && img) {
    art.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3v10.55A4 4 0 1 0 14 17V7h4V3h-6z"/></svg>';
  }

  const state = $('now-state');
  if (!title) {
    state.textContent = 'Nada sonando';
    state.className = 'now-state';
    $('now-title').textContent = 'Busca algo para ponerlo en el proyector';
  } else {
    state.textContent = m.playing ? `Reproduciéndose en ${p.name}` : 'En pausa';
    state.className = `now-state${m.playing ? ' live' : ''}`;
    $('now-title').textContent = title;
  }
  $('now-queue').hidden = !(q.active && q.info);
  $('now-queue').textContent = q.info || '';
  $('btn-next').hidden = !q.active;
  // SVG elements have no `hidden` property; set the attribute.
  $('icon-play').toggleAttribute('hidden', !!m.playing);
  $('icon-pause').toggleAttribute('hidden', !m.playing);
  $('btn-toggle').setAttribute('aria-label', m.playing ? 'Pausar' : 'Reproducir');
  renderVolume();
}

function sameTitle(a, b) {
  const norm = (s) => String(s || '').toLowerCase().replace(/[^\p{L}\p{N}]+/gu, '');
  const x = norm(a);
  const y = norm(b);
  return !!x && !!y && (x.includes(y) || y.includes(x));
}

function renderVolume() {
  const v = volume;
  const pct = v && v.max ? Math.round((v.level / v.max) * 100) : 0;
  $('vol-fill').style.width = `${pct}%`;
  document.querySelector('.volume').classList.toggle('muted', !!(v && v.muted));
  $('btn-mute').classList.toggle('active', !!(v && v.muted));
  $('btn-mute').setAttribute('aria-label', v && v.muted ? 'Quitar silencio' : 'Silenciar');
}

function renderScreens() {
  const list = $('screens-list');
  list.replaceChildren();
  const sel = current();
  for (const p of store.projectors) {
    const li = document.createElement('li');
    li.className = `screen-row${sel && sel.id === p.id ? ' selected' : ''}`;
    const pick = document.createElement('button');
    pick.type = 'button';
    pick.className = 'pick';
    const dot = document.createElement('span');
    const st = status[p.id] || 'unknown';
    dot.className = `dot ${st === 'online' ? 'on' : st === 'unknown' ? '' : 'off'}`;
    const name = document.createElement('span');
    name.textContent = p.name;
    pick.append(dot, name);
    pick.addEventListener('click', () => select(p.id));
    const remove = document.createElement('button');
    remove.type = 'button';
    remove.className = 'remove';
    remove.textContent = 'Quitar';
    remove.addEventListener('click', () => removeProjector(p, remove));
    li.append(pick, remove);
    list.append(li);
  }
  $('phone-name-label').textContent = store.phoneName || defaultPhoneName();
}

function select(id) {
  store.selected = id;
  health = null;
  volume = null;
  saveStore();
  closeSheets();
  render();
  refresh();
}

function removeProjector(p, btn) {
  // Two taps instead of confirm(): a native dialog blocks the page.
  if (btn.dataset.armed !== '1') {
    btn.dataset.armed = '1';
    btn.textContent = '¿Seguro?';
    setTimeout(() => { btn.dataset.armed = ''; btn.textContent = 'Quitar'; }, 3000);
    return;
  }
  // Best effort: the projector forgets this phone and stops what it sent.
  if (store.phoneName) api(p, 'unpair', { method: 'POST', body: { phoneName: store.phoneName } });
  store.projectors = store.projectors.filter((x) => x.id !== p.id);
  delete store.lastSent[p.id];
  if (store.selected === p.id) {
    store.selected = store.projectors[0] ? store.projectors[0].id : null;
    health = null;
    volume = null;
  }
  saveStore();
  renderScreens();
  render();
  if (!store.projectors.length) closeSheets();
  else refresh();
}

$('screen-chip').addEventListener('click', async () => {
  renderScreens();
  openSheet('sheet-screens');
  try {
    const v = await (await fetch('version.json', { cache: 'no-store' })).json();
    $('version').textContent = `versión ${v.version}`;
  } catch {
    $('version').textContent = '';
  }
  // Refresh every projector's dot while the list is open.
  await Promise.all(store.projectors.map(async (p) => {
    const r = await api(p, 'health');
    if (r.status === 200 && status[p.id] !== 'unauthorized') status[p.id] = 'online';
    else if (r.status !== 0 && r.status !== 200) status[p.id] = 'offline';
  }));
  if (!$('sheet-screens').hidden) renderScreens();
  render();
});

// ---------------------------------------------------------------------------
// Polling only while Ahora is on screen.

setInterval(() => {
  if (document.visibilityState === 'visible' && tab === 'now' && current()) refresh();
}, POLL_MS);
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible') refresh();
});

// A pairing link in the address (#pair?v=1&id=…), for a future https QR.
if (location.hash.startsWith('#pair?')) {
  const text = location.hash;
  history.replaceState(null, '', location.pathname);
  addFromText(text);
}

render();
refresh();
