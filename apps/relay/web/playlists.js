'use strict';

// Playlists tab. Port of apps/control/lib/playlists_page.dart: the user's
// Spotify playlists (pinned ones as cards on top), a playlist's songs, and
// "Aleatorio en <pantalla>", which hands the songs to the projector's queue
// (it finds each video itself). Loaded before app.js; uses its helpers and
// spotify.js at call time.

const LIKED_ID = 'liked';
// The Spotify user id of this phone's session: in development mode Spotify
// only lets the app read playlists this user owns.
let spotifyMe = null;
let playlistsLoading = false;
let playlistsError = '';
// The open playlist: {playlist, tracks|null, error, newestFirst}.
let openList = null;

async function loadPlaylists(force = false) {
  if (!spotifyLoggedIn() || playlistsLoading || (playlists && !force)) return;
  playlistsLoading = true;
  playlistsError = '';
  renderPlaylists();
  try {
    if (!spotifyMe) {
      const me = await sp('/me');
      if (me.ok) spotifyMe = (await me.json()).id || null;
    }
    const res = await sp('/me/playlists?limit=50');
    if (!res.ok) throw new Error(`Spotify ${res.status}`);
    const j = await res.json();
    playlists = [
      { id: LIKED_ID, name: 'Canciones que te gustan', total: 0, image: null, owner: '', ownerId: '' },
      ...(j.items || []).filter(Boolean).map((p) => ({
        id: p.id,
        name: p.name || '',
        total: (p.tracks && p.tracks.total) || (p.items && p.items.total) || 0,
        // The smallest image, like the app: enough for a 52 px row.
        image: p.images && p.images.length ? p.images[p.images.length - 1].url : null,
        owner: (p.owner && p.owner.display_name) || '',
        ownerId: (p.owner && p.owner.id) || '',
      })),
    ];
  } catch (e) {
    playlistsError = e.message;
  } finally {
    playlistsLoading = false;
    renderPlaylists();
  }
}

async function tracksOf(id) {
  if (playlistTracks.has(id)) return playlistTracks.get(id);
  let next = id === LIKED_ID
    ? 'https://api.spotify.com/v1/me/tracks?limit=50'
    // /items, not /tracks: the old endpoint answers 403 to apps in development mode.
    : `https://api.spotify.com/v1/playlists/${encodeURIComponent(id)}/items?limit=100`;
  const out = [];
  while (next && out.length < 1000) {
    const res = await sp(next.replace('https://api.spotify.com/v1', ''));
    if (res.status === 403 || res.status === 404) {
      throw new Error(`Spotify no deja leer esta playlist desde la app (${res.status}). Las playlists editoriales de Spotify están cerradas para apps en modo desarrollo.`);
    }
    if (!res.ok) throw new Error(`Spotify ${res.status}`);
    const j = await res.json();
    for (const item of j.items || []) {
      // /items brings the song in "item"; /me/tracks still in "track".
      const t = item && (item.item || item.track);
      if (!t || t.is_local || t.type !== 'track') continue;
      const images = (t.album && t.album.images) || [];
      out.push({
        uri: t.uri || null,
        title: t.name || '',
        artists: (t.artists || []).map((a) => a.name).filter(Boolean),
        artUrl: images.length ? images[images.length - 1].url : null,
        addedAt: item.added_at ? Date.parse(item.added_at) : null,
      });
    }
    next = j.next || null;
  }
  playlistTracks.set(id, out);
  return out;
}

function isPinned(id) {
  return store.pinned.includes(id);
}

/// Spotify answers 403/404 to a development-mode app for playlists the user
/// does not own (editorial ones and other people's), so they cannot open.
function isLocked(pl) {
  if (pl.id === LIKED_ID) return false;
  return pl.ownerId === 'spotify' || (!!spotifyMe && pl.ownerId !== spotifyMe);
}

function lockedReason(pl) {
  return pl.ownerId === 'spotify' ? 'No disponible (editorial de Spotify)'
    : `No disponible (es de ${pl.owner || 'otra cuenta'})`;
}

function togglePin(pl) {
  if (isLocked(pl)) return;
  store.pinned = isPinned(pl.id) ? store.pinned.filter((x) => x !== pl.id) : [...store.pinned, pl.id];
  saveStore();
  toast(isPinned(pl.id) ? `"${pl.name}" fijada arriba` : `"${pl.name}" ya no está fijada`);
  renderPlaylists();
}

// --- Long press (pin a playlist, queue from a song) ---------------------------

/// Calls onTap on a tap and onHold after holding ~half a second.
function pressable(el, onTap, onHold) {
  let timer = 0;
  let held = false;
  let start = null;
  const cancel = () => {
    clearTimeout(timer);
    timer = 0;
  };
  el.addEventListener('pointerdown', (e) => {
    held = false;
    start = { x: e.clientX, y: e.clientY };
    cancel();
    timer = setTimeout(() => {
      held = true;
      timer = 0;
      if (navigator.vibrate) navigator.vibrate(15);
      onHold();
    }, 500);
  });
  el.addEventListener('pointermove', (e) => {
    if (start && Math.hypot(e.clientX - start.x, e.clientY - start.y) > 10) cancel();
  });
  el.addEventListener('pointerup', cancel);
  el.addEventListener('pointercancel', cancel);
  el.addEventListener('pointerleave', cancel);
  el.addEventListener('contextmenu', (e) => e.preventDefault());
  el.addEventListener('click', (e) => {
    if (held) {
      e.preventDefault();
      held = false;
      return;
    }
    onTap();
  });
}

// --- Rendering: the list ---------------------------------------------------------

function cover(url, size, icon, radius = 10) {
  const box = document.createElement('div');
  box.className = 'cover';
  box.style.width = size;
  box.style.borderRadius = `${radius}px`;
  if (url) {
    const img = document.createElement('img');
    img.alt = '';
    img.loading = 'lazy';
    img.src = url;
    img.onerror = () => img.remove();
    box.append(img);
  }
  box.insertAdjacentHTML('afterbegin', `<svg><use href="#${icon}"/></svg>`);
  return box;
}

// Polling calls render() every few seconds: rebuild a list only when what it
// shows changed, so a tap or a long press on a row is never cut in half.
let playlistsKey = '';
let tracksKey = '';

function renderPlaylists() {
  const body = $('playlists-body');
  if (!body || !spotifyLoggedIn()) return;
  const key = JSON.stringify([playlists && playlists.map((x) => x.id + x.total), store.pinned, playlistsLoading, playlistsError, spotifyMe]);
  if (key === playlistsKey) return;
  playlistsKey = key;
  body.replaceChildren();
  if (playlistsLoading && !playlists) {
    body.innerHTML = '<div class="center-state"><span class="spinner big"></span></div>';
    return;
  }
  if (playlistsError) {
    const n = document.createElement('p');
    n.className = 'notice-text error';
    n.textContent = playlistsError;
    body.append(n);
  }
  // Yours first; the ones Spotify does not let the app read, at the end.
  const all = [...(playlists || []).filter((p) => !isLocked(p)), ...(playlists || []).filter(isLocked)];
  const pinned = all.filter((p) => isPinned(p.id) && !isLocked(p));
  if (pinned.length) {
    body.insertAdjacentHTML('beforeend', '<p class="section-label">Fijadas</p>');
    const grid = document.createElement('div');
    grid.className = 'pinned-grid';
    for (const pl of pinned) {
      const card = document.createElement('button');
      card.type = 'button';
      card.className = 'pinned-card';
      card.append(cover(pl.id === LIKED_ID ? null : pl.image, '100%', pl.id === LIKED_ID ? 'i-favorite' : 'i-queue-music', 18));
      const name = document.createElement('b');
      name.textContent = pl.name;
      const sub = document.createElement('small');
      sub.textContent = pl.total > 0 ? `${pl.total} canciones` : pl.owner;
      card.append(name, sub);
      pressable(card, () => openPlaylist(pl), () => togglePin(pl));
      grid.append(card);
    }
    body.append(grid);
    body.insertAdjacentHTML('beforeend', '<p class="section-label spaced">Todas</p>');
  } else if (all.length) {
    body.insertAdjacentHTML('beforeend', '<p class="hint">Mantén presionada una playlist para fijarla arriba.</p>');
  }
  const list = document.createElement('div');
  list.className = 'pl-rows';
  for (const pl of all.filter((p) => !pinned.includes(p))) {
    const locked = isLocked(pl);
    const row = document.createElement('button');
    row.type = 'button';
    row.className = `pl-row${locked ? ' locked' : ''}`;
    if (pl.id === LIKED_ID) {
      row.insertAdjacentHTML('beforeend', '<div class="cover liked"><svg><use href="#i-favorite"/></svg></div>');
    } else {
      row.append(cover(pl.image, '52px', 'i-queue-music'));
    }
    const text = document.createElement('span');
    text.className = 'pl-text';
    const name = document.createElement('b');
    name.textContent = pl.name;
    const sub = document.createElement('small');
    sub.textContent = locked ? lockedReason(pl)
      : [pl.total > 0 ? `${pl.total} canciones` : '', pl.owner].filter(Boolean).join(' · ');
    text.append(name, sub);
    row.append(text);
    if (!locked) pressable(row, () => openPlaylist(pl), () => togglePin(pl));
    list.append(row);
  }
  body.append(list);
  const again = document.createElement('button');
  again.type = 'button';
  again.className = 'link refresh-link';
  again.textContent = playlistsLoading ? 'Actualizando…' : 'Actualizar';
  again.disabled = playlistsLoading;
  again.addEventListener('click', () => loadPlaylists(true));
  body.append(again);
}

// --- A playlist's songs (pushed screen) --------------------------------------

async function openPlaylist(pl) {
  openList = { playlist: pl, tracks: playlistTracks.get(pl.id) || null, error: '', newestFirst: true };
  pushView('tracks');
  if (openList.tracks) return;
  try {
    const tracks = await tracksOf(pl.id);
    if (openList && openList.playlist === pl) openList.tracks = tracks;
  } catch (e) {
    if (openList && openList.playlist === pl) {
      openList.error = e.message;
      openList.tracks = [];
    }
  }
  renderTracks();
}

function sortedTracks() {
  const t = (openList && openList.tracks) || [];
  return openList.newestFirst ? [...t].sort((a, b) => (b.addedAt || 0) - (a.addedAt || 0)) : t;
}

function ago(ms) {
  if (!ms) return '';
  const d = Math.floor((Date.now() - ms) / 86400000);
  if (d < 1) return 'agregada hoy';
  if (d < 30) return `hace ${d} d`;
  const months = Math.floor(d / 30);
  if (d < 365) return `hace ${months} ${months === 1 ? 'mes' : 'meses'}`;
  const years = Math.floor(d / 365);
  return `hace ${years} ${years === 1 ? 'año' : 'años'}`;
}

function renderTracks() {
  const box = $('view-tracks');
  if (!box || !openList || view !== 'tracks') return;
  const p = current();
  const online = stateOf(p) === 'online';
  const pl = openList.playlist;
  const tracks = openList.tracks;
  const key = JSON.stringify([pl.id, tracks && tracks.length, openList.newestFirst, openList.error, queueing,
    online, p && p.name, sentKey, spotifyBusy]);
  if (key === tracksKey) return;
  tracksKey = key;
  box.replaceChildren();

  const head = document.createElement('div');
  head.className = 'tracks-head';
  head.append(cover(pl.id === LIKED_ID ? null : pl.image, '104px', pl.id === LIKED_ID ? 'i-favorite' : 'i-queue-music', 18));
  const text = document.createElement('div');
  text.className = 'tracks-title';
  const h = document.createElement('h2');
  h.textContent = pl.name;
  const sub = document.createElement('p');
  sub.textContent = tracks === null ? 'Cargando…'
    : `${tracks.length} canciones${openList.newestFirst ? ' · más recientes primero' : ''}`;
  text.append(h, sub);
  const sort = document.createElement('button');
  sort.type = 'button';
  sort.className = 'icon-btn';
  sort.setAttribute('aria-label', openList.newestFirst ? 'Orden de Spotify' : 'Más recientes primero');
  sort.innerHTML = `<svg><use href="#${openList.newestFirst ? 'i-schedule' : 'i-numbered'}"/></svg>`;
  sort.addEventListener('click', () => {
    openList.newestFirst = !openList.newestFirst;
    renderTracks();
  });
  head.append(text, sort);
  box.append(head);

  const shuffle = document.createElement('button');
  shuffle.type = 'button';
  shuffle.className = 'btn primary big';
  shuffle.innerHTML = queueing ? '<span class="spinner dark"></span>' : '<svg><use href="#i-shuffle"/></svg>';
  shuffle.append(document.createTextNode(`Aleatorio en ${p ? p.name : 'la pantalla'}`));
  shuffle.disabled = queueing || !online || !tracks || !tracks.length;
  shuffle.addEventListener('click', () => playQueue(tracks, pl.name, true, 0));
  box.append(shuffle);
  if (p && !online) {
    const off = document.createElement('p');
    off.className = 'hint center';
    off.textContent = `${p.name} no responde: elige otra pantalla en Ahora.`;
    box.append(off);
  }

  if (openList.error) {
    const n = document.createElement('p');
    n.className = 'notice-text error';
    n.textContent = openList.error;
    box.append(n);
  } else if (tracks === null) {
    box.insertAdjacentHTML('beforeend', '<div class="center-state"><span class="spinner big"></span></div>');
  } else if (!tracks.length) {
    box.insertAdjacentHTML('beforeend', '<p class="hint center">Esta playlist está vacía</p>');
  }

  const list = document.createElement('div');
  list.className = 'track-rows';
  const ordered = tracks ? sortedTracks() : [];
  ordered.forEach((t, i) => {
    const row = document.createElement('button');
    row.type = 'button';
    const sent = sentKey === trackKey(t);
    row.className = `track-row${sent ? ' sent' : ''}`;
    row.disabled = !online || spotifyBusy;
    row.append(cover(t.artUrl, '52px', 'i-note'));
    const tx = document.createElement('span');
    tx.className = 'pl-text';
    const b = document.createElement('b');
    b.textContent = t.title;
    const s = document.createElement('small');
    s.textContent = [t.artists.join(', '), ago(t.addedAt)].filter(Boolean).join(' · ');
    tx.append(b, s);
    row.append(tx);
    if (sent && p) {
      const chip = document.createElement('span');
      chip.className = 'live-chip on';
      chip.textContent = p.name;
      row.append(chip);
    }
    // Tap: this song's video. Hold: the queue in this order, from this song.
    pressable(row, () => sendTrack(t), () => playQueue(ordered, pl.name, false, i));
    list.append(row);
  });
  box.append(list);
}

// --- The projector's queue -------------------------------------------------------

let queueing = false;

async function playQueue(tracks, name, shuffle, startAt) {
  const p = current();
  if (!p) {
    toast('No hay pantalla: escanea el QR del proyector', { error: true });
    return;
  }
  if (!tracks || !tracks.length || queueing) return;
  queueing = true;
  renderTracks();
  toast('Armando la cola…');
  let items = tracks.slice(0, 1000).map((t) => ({ title: t.title, artists: t.artists, artUrl: t.artUrl }));
  // The relay takes up to 256 KB: without covers if a long list would not fit.
  if (JSON.stringify(items).length > 200000) items = items.map(({ title, artists }) => ({ title, artists }));
  try {
    const r = await api(p, 'queue', { method: 'POST', body: { tracks: items, name, shuffle, startAt } });
    if (r.status === 504) {
      // The projector is still looking for the first video; it will start.
      toast(`${p.name} sigue armando la cola…`);
    } else if (r.status !== 200 || !r.data.ok) {
      toast(errorText(r, p), { error: true });
    } else {
      if (health) health.queue = { active: !!r.data.info, info: r.data.info || null };
      toast(r.data.info ? `Sonando en ${p.name}: ${r.data.info}` : 'No encontré videos para esta playlist');
    }
  } finally {
    queueing = false;
    renderTracks();
    setTimeout(refresh, 1500);
  }
}
