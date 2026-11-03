'use strict';

// Máscara de proyección. Port of apps/control/lib/mask_page.dart: a 16:9
// canvas stands for the projected image; closed shapes drawn with a finger
// are the visible areas and the projector blacks out the rest, live. Shapes
// are normalized to 0..1. Loaded after app.js: it wires its controls with
// app.js helpers on load.

const MASK_MIN_STEP = 0.006;
const MASK_THROTTLE_MS = 120;

// {pid, shapes, current, feather, outline, timer, sending, pending}
let mask = null;

function openMask(p) {
  select(p.id);
  mask = { pid: p.id, shapes: [], current: [], feather: 0.015, outline: true, timer: 0, sending: false, pending: false };
  $('mask-feather').value = String(mask.feather);
  $('mask-outline').checked = mask.outline;
  paintFeather();
  $('mask-status').textContent = '';
  pushView('mask');
  requestAnimationFrame(drawMask);
}

function maskProjector() {
  return mask && store.projectors.find((x) => x.id === mask.pid);
}

function maskPayload() {
  const all = [...mask.shapes, mask.current].filter((s) => s.length >= 3);
  return all.map((s) => s.flatMap((pt) => [round4(pt.x), round4(pt.y)]));
}

function round4(n) {
  return Math.round(n * 10000) / 10000;
}

/// Sends at most every 120 ms while drawing (the projector is slow), one
/// request at a time.
function sendLive() {
  if (!mask) return;
  mask.pending = true;
  if (!mask.timer) mask.timer = setTimeout(() => flushMask(false), MASK_THROTTLE_MS);
}

async function flushMask(save) {
  if (!mask) return null;
  mask.timer = 0;
  if (mask.sending) {
    mask.pending = true;
    return null;
  }
  const p = maskProjector();
  if (!p) return null;
  mask.pending = false;
  mask.sending = true;
  const shapes = maskPayload();
  // save:false while drawing: only "Guardar máscara" keeps it after a restart.
  const body = shapes.length
    ? { shapes, feather: mask.feather, outline: mask.outline, save }
    : { clear: true };
  let r;
  try {
    r = await api(p, 'mask', { method: 'POST', body });
    if (r.status !== 200 || !r.data.ok) $('mask-status').textContent = errorText(r, p);
    else if (!save) $('mask-status').textContent = '';
  } finally {
    if (mask) {
      mask.sending = false;
      if (mask.pending) sendLive();
    }
  }
  return r;
}

async function saveMask() {
  if (!mask || !mask.shapes.length) return;
  // The calibration outline is not part of the saved mask.
  mask.outline = false;
  $('mask-outline').checked = false;
  clearTimeout(mask.timer);
  mask.timer = 0;
  while (mask && mask.sending) await new Promise((r) => setTimeout(r, 50));
  const r = await flushMask(true);
  if (r && r.status === 200 && r.data.ok) toast('Máscara guardada en el proyector');
}

async function removeMask() {
  const p = maskProjector();
  if (!mask || !p) return;
  mask.shapes = [];
  mask.current = [];
  clearTimeout(mask.timer);
  mask.timer = 0;
  mask.pending = false;
  drawMask();
  renderMask();
  const r = await api(p, 'mask', { method: 'POST', body: { clear: true } });
  $('mask-status').textContent = r.status === 200 && r.data.ok ? 'Máscara quitada' : errorText(r, p);
}

// --- Drawing -------------------------------------------------------------------

function maskPoint(e) {
  const r = $('mask-canvas').getBoundingClientRect();
  return {
    x: Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)),
    y: Math.min(1, Math.max(0, (e.clientY - r.top) / r.height)),
  };
}

function maskOnline() {
  return stateOf(maskProjector()) === 'online';
}

$('mask-canvas').addEventListener('pointerdown', (e) => {
  if (!mask || !maskOnline()) return;
  e.preventDefault();
  $('mask-canvas').setPointerCapture(e.pointerId);
  mask.current = [maskPoint(e)];
  drawMask();
});
$('mask-canvas').addEventListener('pointermove', (e) => {
  if (!mask || !mask.current.length) return;
  const pt = maskPoint(e);
  const last = mask.current[mask.current.length - 1];
  if (Math.hypot(pt.x - last.x, pt.y - last.y) < MASK_MIN_STEP) return;
  mask.current.push(pt);
  drawMask();
  sendLive();
});
const endStroke = () => {
  if (!mask || !mask.current.length) return;
  if (mask.current.length >= 3) mask.shapes.push(mask.current);
  mask.current = [];
  drawMask();
  renderMask();
  sendLive();
};
$('mask-canvas').addEventListener('pointerup', endStroke);
$('mask-canvas').addEventListener('pointercancel', endStroke);

function drawMask() {
  const canvas = $('mask-canvas');
  if (!mask || canvas.offsetParent === null) return;
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth;
  const h = canvas.clientHeight;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = '#000';
  ctx.fillRect(0, 0, w, h);
  ctx.lineWidth = 2;
  ctx.lineJoin = 'round';
  ctx.strokeStyle = '#fff';
  for (const s of mask.shapes) {
    ctx.beginPath();
    s.forEach((pt, i) => (i ? ctx.lineTo(pt.x * w, pt.y * h) : ctx.moveTo(pt.x * w, pt.y * h)));
    ctx.closePath();
    ctx.fillStyle = '#8e8aa8';
    ctx.fill();
    ctx.stroke();
  }
  if (mask.current.length >= 2) {
    ctx.beginPath();
    mask.current.forEach((pt, i) => (i ? ctx.lineTo(pt.x * w, pt.y * h) : ctx.moveTo(pt.x * w, pt.y * h)));
    ctx.stroke();
  }
  ctx.strokeStyle = 'rgba(255,255,255,.24)';
  ctx.lineWidth = 1;
  ctx.strokeRect(0.5, 0.5, w - 1, h - 1);
}

window.addEventListener('resize', () => {
  if (view === 'mask') drawMask();
});

// --- Controls --------------------------------------------------------------------

function paintFeather() {
  const el = $('mask-feather');
  el.style.setProperty('--fill', `${(Number(el.value) / Number(el.max)) * 100}%`);
}

$('mask-feather').addEventListener('input', () => {
  if (mask) mask.feather = Number($('mask-feather').value);
  paintFeather();
});
// Sent on release, like the app's slider.
$('mask-feather').addEventListener('change', sendLive);
$('mask-outline').addEventListener('change', () => {
  if (!mask) return;
  mask.outline = $('mask-outline').checked;
  sendLive();
});
$('mask-undo').addEventListener('click', () => {
  if (!mask || !mask.shapes.length) return;
  mask.shapes.pop();
  drawMask();
  renderMask();
  sendLive();
});
$('mask-clear').addEventListener('click', removeMask);
$('mask-save').addEventListener('click', saveMask);

function renderMask() {
  if (!mask || view !== 'mask') return;
  const online = maskOnline();
  $('mask-help').textContent = online
    ? 'Dibuja con el dedo dónde quieres ver la imagen. Lo demás queda negro. Mira la casa mientras dibujas: se actualiza en vivo.'
    : 'La pantalla no responde: revisa que esté prendida.';
  $('mask-undo').disabled = !mask.shapes.length;
  $('mask-save').disabled = !online || !mask.shapes.length;
  $('mask-canvas').classList.toggle('off', !online);
  drawMask();
}
