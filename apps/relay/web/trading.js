'use strict';

// Trading tab. Port of apps/control/lib/trading_page.dart with one change: the
// log lives on the projector (trading.json), not on the phone. The projector
// prices it with Yahoo and computes every number (GET /trading answers with
// the stats already done), so the phone and the TV always agree and this page
// needs neither Yahoo (no CORS) nor the P&L math. Edits send the whole list
// back (POST /trading {trades}), the same contract the Flutter app used.
//
// Loaded after app.js: uses its helpers (api, current, connected, toast…).

const TRADING_POLL_MS = 10000;

let trading = null; // the projector's last answer
let tradingFor = null; // which projector it came from
let tradingProblem = null; // 'old' (receiver without GET /trading) or a message
let tradingLoading = false;
let tradingSaving = false;

async function loadTrading() {
  const p = current();
  if (!p || tradingLoading) return;
  if (tradingFor !== p.id) {
    trading = null;
    tradingProblem = null;
  }
  if (!connected(p)) {
    renderTrading();
    return;
  }
  tradingLoading = true;
  try {
    const r = await api(p, 'trading');
    if (p !== current()) return;
    if (r.status === 200 && r.data.ok) {
      trading = r.data;
      tradingFor = p.id;
      tradingProblem = null;
    } else if (r.status === 404) {
      tradingProblem = 'old';
    } else if (r.status !== 0) {
      tradingProblem = errorText(r, p);
    }
  } finally {
    tradingLoading = false;
    renderTrading();
  }
}

setInterval(() => {
  if (document.visibilityState === 'visible' && tab === 'trading' && view === 'tabs') loadTrading();
}, TRADING_POLL_MS);

/// Sends the whole log to the projector. Only after a successful read from
/// that same projector: a POST with a list it never had would wipe its file.
async function saveTrades(list) {
  const p = current();
  if (!p || !trading || tradingFor !== p.id || tradingSaving) return false;
  tradingSaving = true;
  try {
    const r = await api(p, 'trading', { method: 'POST', body: { trades: list } });
    if (r.status === 200 && r.data.ok) {
      trading = { ...trading, ...r.data };
      return true;
    }
    toast(errorText(r, p), { error: true });
    return false;
  } finally {
    tradingSaving = false;
    renderTrading();
  }
}

// --- Formatting: the same as packages/shared (money, pct, qtyText) ------------

/// "+$1,234.56" / "−$12.00" (U+2212, like the TV) / "—" without data.
function money(v, sign = true) {
  if (v === null || v === undefined || Number.isNaN(v)) return '—';
  const abs = Math.abs(v).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const prefix = !sign ? (v < 0 ? '−' : '') : v > 0 ? '+' : v < 0 ? '−' : '';
  return `${prefix}$${abs}`;
}

function pct(v) {
  if (v === null || v === undefined) return '—';
  return `${v > 0 ? '+' : v < 0 ? '−' : ''}${Math.abs(v).toFixed(2)}%`;
}

/// Whole shares without decimals; fractions with up to 4 (buying by amount).
function qtyText(v) {
  return Number.isInteger(v) ? String(v) : String(Number(v.toFixed(4)));
}

function tone(v) {
  return v > 0 ? 'up' : v < 0 ? 'down' : '';
}

function sideText(side) {
  return side === 'short' ? 'Corto' : 'Largo';
}

/// Local "2026-11-03T14:05:00.000", which Dart's DateTime.parse reads as local
/// time on the projector (toISOString's UTC would move trades across days).
function localIso(d) {
  const z = (n, w = 2) => String(n).padStart(w, '0');
  return `${d.getFullYear()}-${z(d.getMonth() + 1)}-${z(d.getDate())}T${z(d.getHours())}:${z(d.getMinutes())}:${z(d.getSeconds())}.${z(d.getMilliseconds(), 3)}`;
}

function dateInputValue(d) {
  return localIso(d).slice(0, 10);
}

/// The date picked in a sheet, at the current time of day (as the app did).
function dateFromInput(value) {
  const now = new Date();
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
  if (!m) return now;
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), now.getHours(), now.getMinutes(), now.getSeconds());
}

function shortDate(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('es-MX', { day: 'numeric', month: 'short' });
}

function parseNumber(text) {
  const v = Number(String(text || '').trim().replace(/,/g, '.').replace(/[$\s]/g, ''));
  return Number.isFinite(v) ? v : null;
}

function newTradeId() {
  const a = new Uint8Array(9);
  crypto.getRandomValues(a);
  return Array.from(a, (b) => 'abcdefghijklmnopqrstuvwxyz0123456789'[b % 36]).join('');
}

// --- Rendering ------------------------------------------------------------------

let tradingKey = '';

function renderTrading() {
  const p = current();
  if (!p || $('view-trading').hidden) return;
  const st = stateOf(p);
  let problem = null;
  if (st === 'unauthorized') problem = [`El código de ${p.name} cambió`, 'En el proyector abre "Vincular teléfono" y escanea el QR otra vez.'];
  else if (st !== 'online') problem = [`${p.name} no está conectado`, 'La bitácora vive en el proyector: prende el proyector y esto se actualiza solo.'];
  else if (tradingProblem === 'old') problem = [`${p.name} tiene una versión vieja`, 'Hay que actualizar la app del proyector para ver Trading aquí.'];
  else if (tradingProblem) problem = ['No pude leer la bitácora', tradingProblem];
  else if (!trading || tradingFor !== p.id) problem = ['Leyendo la bitácora…', ''];

  $('trading-state').hidden = !problem;
  $('trading-body').hidden = !!problem;
  if (problem) {
    $('trading-state-title').textContent = problem[0];
    $('trading-state-text').textContent = problem[1];
    $('trading-state-text').hidden = !problem[1];
    tradingKey = '';
    return;
  }

  const s = trading.stats || {};
  const key = JSON.stringify([s, trading.quotesAt, trading.nextQuotesAt, trading.quotesLoading, trading.quotesError,
    trading.overlay, p.name, tradingSaving, store.projectors.map((x) => x.id + stateOf(x))]);
  if (key === tradingKey) {
    renderMarketLine();
    return;
  }
  tradingKey = key;

  const set = (id, v, pctV) => {
    const el = $(id);
    el.textContent = money(v) + (pctV !== undefined ? ` · ${pct(pctV)}` : '');
    el.className = el.className.replace(/\b(up|down)\b/g, '').trim();
    if (tone(v)) el.classList.add(tone(v));
  };
  set('tr-day', s.dayTotal);
  set('tr-open', s.unrealizedPnl);
  set('tr-real', s.realizedTotal);
  set('tr-total', s.totalPnl);
  renderMarketLine();

  const showBtn = $('tr-show');
  showBtn.querySelector('span').textContent = trading.overlay ? 'Quitar del video' : `Mostrar en ${p.name}`;
  showBtn.disabled = tradingSaving;
  $('tr-add').disabled = tradingSaving;

  // Open positions: tap to close (or delete without selling).
  const list = $('tr-positions');
  list.replaceChildren();
  const positions = s.positions || [];
  if (!positions.length) {
    const li = document.createElement('li');
    li.className = 'trade-empty';
    li.textContent = 'Ninguna. Registra tu primer movimiento.';
    list.append(li);
  }
  for (const pos of positions) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'trade-row';
    b.innerHTML = `
      <span class="tr-main"><b></b><small></small></span>
      <span class="tr-side"><b></b><small></small></span>`;
    const [main, side] = b.children;
    main.children[0].textContent = pos.symbol;
    main.children[0].insertAdjacentHTML('beforeend', `<em class="tag ${pos.side}">${sideText(pos.side)}</em>`);
    main.children[1].textContent = `${qtyText(pos.qty)} acc. · entrada ${money(pos.avgEntry, false)}`
      + (pos.price !== null && pos.price !== undefined ? ` · ahora ${money(pos.price, false)}` : '');
    side.children[0].textContent = money(pos.unrealized);
    side.children[0].className = tone(pos.unrealized);
    side.children[1].textContent = pos.unrealizedPct !== null && pos.unrealizedPct !== undefined
      ? `${pct(pos.unrealizedPct)} · hoy ${money(pos.dayPnl)}` : 'sin precio';
    b.addEventListener('click', () => openClosePosition(pos));
    li.append(b);
    list.append(li);
  }

  // Closed trades: tap to delete a wrong one.
  const closed = s.closed || [];
  $('tr-closed-label').hidden = !closed.length;
  const cl = $('tr-closed');
  cl.replaceChildren();
  for (const t of closed.slice(0, 30)) {
    const li = document.createElement('li');
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'trade-row';
    b.innerHTML = '<span class="tr-main"><b></b><small></small></span><span class="tr-side"><b></b><small></small></span>';
    const [main, side] = b.children;
    main.children[0].textContent = t.symbol;
    main.children[0].insertAdjacentHTML('beforeend', `<em class="tag ${t.side}">${sideText(t.side)}</em>`);
    main.children[1].textContent = `${qtyText(t.qty)} acc. · ${money(t.entryPrice, false)} → ${money(t.exitPrice, false)}`;
    side.children[0].textContent = money(t.realizedPnl);
    side.children[0].className = tone(t.realizedPnl);
    side.children[1].textContent = shortDate(t.closedAt);
    b.addEventListener('click', () => confirmTrade(
      `¿Borrar este movimiento de ${t.symbol}?`,
      `${money(t.entryPrice, false)} → ${money(t.exitPrice, false)} · ${money(t.realizedPnl)}. Deja de contar en el realizado.`,
      'Borrar',
      () => saveTrades(trading.trades.filter((x) => x.id !== t.id)),
    ));
    li.append(b);
    cl.append(li);
  }

  // Copy this log to another screen that answers (the house has one log).
  const other = store.projectors.find((x) => x.id !== p.id && stateOf(x) === 'online');
  const copy = $('tr-copy');
  copy.hidden = !other || !trading.trades.length;
  if (other) {
    copy.textContent = `Copiar esta bitácora a ${other.name}`;
    copy.dataset.id = other.id;
  }
}

/// "Mercado abierto · precios de hace 40 s" / "Mercado cerrado · abre en 14 h".
function renderMarketLine() {
  if (!trading) return;
  const el = $('tr-market');
  const parts = [];
  parts.push(trading.marketOpen ? 'Mercado abierto' : 'Mercado cerrado');
  if (trading.quotesLoading) parts.push('pidiendo precios…');
  else if (trading.quotesError) parts.push(trading.quotesError);
  else if (trading.quotesAt) {
    const secs = Math.max(0, Math.round((Date.now() - Date.parse(trading.quotesAt)) / 1000));
    parts.push(secs < 90 ? `precios de hace ${secs} s` : `precios de hace ${Math.round(secs / 60)} min`);
  } else if ((trading.stats && trading.stats.positions || []).length) {
    parts.push('sin precios todavía');
  }
  el.textContent = parts.join(' · ');
}

// --- Sheets -----------------------------------------------------------------------

let tfSide = 'long';
let tfBy = 'amount';

function openTradeSheet() {
  tfSide = 'long';
  tfBy = 'amount';
  $('tf-symbol').value = '';
  $('tf-amount').value = '';
  $('tf-price').value = '';
  $('tf-date').value = dateInputValue(new Date());
  $('tf-error').hidden = true;
  paintTradeForm();
  openSheet('sheet-trade');
  $('tf-symbol').focus();
}

function tradeQty() {
  const n = parseNumber($('tf-amount').value);
  if (tfBy === 'qty') return n;
  const price = parseNumber($('tf-price').value);
  return n && price && price > 0 ? n / price : null;
}

function paintTradeForm() {
  for (const b of document.querySelectorAll('[data-side]')) b.classList.toggle('on', b.dataset.side === tfSide);
  for (const b of document.querySelectorAll('[data-by]')) b.classList.toggle('on', b.dataset.by === tfBy);
  $('tf-amount-label').textContent = tfBy === 'amount' ? 'Monto (USD)' : 'Acciones';
  $('tf-amount').placeholder = tfBy === 'amount' ? '50' : '1.5';
  const q = tradeQty();
  $('tf-calc').textContent = tfBy === 'amount' && q ? `= ${qtyText(q)} acciones` : '';
}

for (const b of document.querySelectorAll('[data-side]')) {
  b.addEventListener('click', () => { tfSide = b.dataset.side; paintTradeForm(); });
}
for (const b of document.querySelectorAll('[data-by]')) {
  b.addEventListener('click', () => { tfBy = b.dataset.by; paintTradeForm(); });
}
for (const id of ['tf-amount', 'tf-price']) $(id).addEventListener('input', paintTradeForm);

$('trade-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const symbol = $('tf-symbol').value.trim().toUpperCase();
  const qty = tradeQty();
  const price = parseNumber($('tf-price').value);
  if (!/^[A-Z0-9.^=-]{1,12}$/.test(symbol) || !qty || qty <= 0 || !price || price <= 0) {
    $('tf-error').textContent = tfBy === 'amount' ? 'Revisa símbolo, monto y precio' : 'Revisa símbolo, cantidad y precio';
    $('tf-error').hidden = false;
    return;
  }
  const t = {
    id: newTradeId(), symbol, side: tfSide, qty, entryPrice: price,
    openedAt: localIso(dateFromInput($('tf-date').value)),
  };
  closeSheets();
  if (await saveTrades([...trading.trades, t])) toast(`${symbol} registrado en ${current().name}`);
});

let closing = null;

function openClosePosition(pos) {
  closing = pos;
  $('cp-title').textContent = `Cerrar ${pos.symbol}`;
  $('cp-info').textContent = `${sideText(pos.side)} · ${qtyText(pos.qty)} acc. · entrada ${money(pos.avgEntry, false)} · invertido ${money(pos.cost, false)}`;
  $('cp-price').value = pos.price ? String(pos.price) : '';
  $('cp-date').value = dateInputValue(new Date());
  $('cp-error').hidden = true;
  paintClose();
  openSheet('sheet-close-pos');
}

/// What closing at the typed price would realize (same math as the projector).
function paintClose() {
  const price = parseNumber($('cp-price').value);
  if (!closing || !price || !trading) {
    $('cp-calc').textContent = '';
    return;
  }
  const sign = closing.side === 'short' ? -1 : 1;
  const pnl = trading.trades
    .filter((t) => closing.tradeIds.includes(t.id))
    .reduce((s, t) => s + (price - t.entryPrice) * t.qty * sign, 0);
  $('cp-calc').textContent = `Resultado: ${money(pnl)}`;
  $('cp-calc').className = `trade-calc ${tone(pnl)}`;
}
$('cp-price').addEventListener('input', paintClose);

$('cp-save').addEventListener('click', async () => {
  const price = parseNumber($('cp-price').value);
  if (!closing || !price || price <= 0) {
    $('cp-error').textContent = 'Precio inválido';
    $('cp-error').hidden = false;
    return;
  }
  const at = localIso(dateFromInput($('cp-date').value));
  const ids = new Set(closing.tradeIds);
  const symbol = closing.symbol;
  closeSheets();
  const list = trading.trades.map((t) => (ids.has(t.id) ? { ...t, exitPrice: price, closedAt: at } : t));
  if (await saveTrades(list)) toast(`${symbol} cerrada`);
});

$('cp-delete').addEventListener('click', () => {
  const pos = closing;
  if (!pos) return;
  const n = pos.tradeIds.length;
  confirmTrade(
    `¿Borrar ${pos.symbol}?`,
    `${qtyText(pos.qty)} acc. · entrada ${money(pos.avgEntry, false)}. ${n === 1 ? 'Se borra sin venderla' : `Se borran sus ${n} movimientos sin venderlos`}: no cuenta en el P&L.`,
    'Borrar',
    () => saveTrades(trading.trades.filter((t) => !pos.tradeIds.includes(t.id))),
  );
});

let confirmAction = null;

function confirmTrade(title, text, okLabel, action) {
  confirmAction = action;
  $('tc-title').textContent = title;
  $('tc-text').textContent = text;
  $('tc-ok').textContent = okLabel;
  openSheet('sheet-trade-confirm');
}

$('tc-ok').addEventListener('click', () => {
  const a = confirmAction;
  confirmAction = null;
  closeSheets();
  if (a) a();
});

$('tr-add').addEventListener('click', () => {
  if (trading) openTradeSheet();
});

$('tr-show').addEventListener('click', async () => {
  const p = current();
  if (!p || !trading) return;
  const body = trading.overlay ? { overlay: false } : { show: true };
  const r = await api(p, 'trading', { method: 'POST', body });
  if (r.status === 200 && r.data.ok) {
    trading = { ...trading, ...r.data };
    toast(r.data.mode === 'overlay' ? 'Tus acciones flotan encima del video (se quitan solas en 45 s)'
      : r.data.mode === 'home' ? `Estadísticas en el inicio de ${p.name}` : 'Video en grande otra vez');
  } else {
    toast(errorText(r, p), { error: true });
  }
  renderTrading();
});

$('tr-copy').addEventListener('click', async () => {
  const target = store.projectors.find((x) => x.id === $('tr-copy').dataset.id);
  if (!target || !trading) return;
  const r = await api(target, 'trading');
  if (r.status === 404) {
    toast(`${target.name} tiene una versión vieja: hay que actualizar su app`, { error: true });
    return;
  }
  if (r.status !== 200 || !r.data.ok) {
    toast(errorText(r, target), { error: true });
    return;
  }
  const theirs = (r.data.trades || []).length;
  const list = trading.trades;
  confirmTrade(
    `¿Copiar a ${target.name}?`,
    theirs
      ? `${target.name} tiene ${theirs} movimientos que se reemplazan por estos ${list.length}.`
      : `${target.name} no tiene movimientos: recibe estos ${list.length}.`,
    theirs ? 'Reemplazar' : 'Copiar',
    async () => {
      const w = await api(target, 'trading', { method: 'POST', body: { trades: list } });
      if (w.status === 200 && w.data.ok) toast(`Bitácora copiada a ${target.name}`);
      else toast(errorText(w, target), { error: true });
    },
  );
});
