'use strict';

// Spotify in the PWA. Port of apps/control/lib/spotify*.dart: the phone's own
// session (PKCE in the browser: Spotify's token and Web API endpoints allow
// CORS, so no relay and no secret), what is playing, "Seguir a Spotify",
// sending the song's video, and handing a separate token to a projector so it
// follows Spotify by itself.
//
// Loaded before app.js and only defines things: it uses app.js helpers (api,
// toast, store, current, render, play…) at call time.

const SPOTIFY_SCOPES = [
  'user-read-currently-playing', 'user-read-playback-state', 'playlist-read-private',
  'playlist-read-collaborative', 'user-library-read', 'user-modify-playback-state',
  // "Me gusta": create proyector_13 and add songs to it.
  'playlist-modify-private', 'playlist-modify-public',
];
// What a projector needs to follow Spotify on its own.
const PROJECTOR_SCOPES = ['user-read-currently-playing', 'user-read-playback-state'];
const SPOTIFY_KEY = 'proyector.spotify';
const PKCE_KEY = 'proyector.spotify.pkce';

const spotifyClientId = (() => {
  const m = document.querySelector('meta[name="spotify-client-id"]');
  const v = m ? m.content : '';
  return /^[A-Za-z0-9]{16,64}$/.test(v) ? v : '';
})();

function spotifyRedirect() {
  return `${location.origin}${location.pathname}`;
}

let spToken = loadSpotifyToken();
// Now playing on the phone's Spotify: {title, artists[], isPlaying, artUrl}.
let track = null;
// Ranked YouTube videos for the last song sent, for "Otro video (n)".
let candidates = [];
// "artist|title" of the last song sent by hand.
let sentKey = null;
let spotifyBusy = false;
// Playlists tab (playlists.js): the list, and tracks per playlist id.
let playlists = null;
const playlistTracks = new Map();

function loadSpotifyToken() {
  try {
    const t = JSON.parse(localStorage.getItem(SPOTIFY_KEY) || 'null');
    return t && t.access_token && t.refresh_token ? t : null;
  } catch {
    return null;
  }
}

function saveSpotifyToken(t) {
  spToken = t;
  try {
    if (t) localStorage.setItem(SPOTIFY_KEY, JSON.stringify(t));
    else localStorage.removeItem(SPOTIFY_KEY);
  } catch {
    // Not persisted: the session lasts this visit.
  }
}

function spotifyLoggedIn() {
  return !!spToken;
}

function dropSpotify() {
  saveSpotifyToken(null);
  track = null;
  playlists = null;
  playlistTracks.clear();
  spotifyMe = null;
  savePlaylistId = null;
}

function spotifyLogout() {
  dropSpotify();
  render();
  renderAddSheet();
}

// --- PKCE --------------------------------------------------------------------

function randomString(n) {
  // 64 symbols: 256 % 64 == 0, so each byte maps without bias.
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  return Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => abc[b % 64]).join('');
}

async function challengeOf(verifier) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier));
  return btoa(String.fromCharCode(...new Uint8Array(digest)))
    .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/// Goes to Spotify and comes back to this page. purpose: 'phone' (this
/// phone's session) or 'link:<projector id>' (a token for that projector).
async function spotifyAuthorize(purpose) {
  if (!spotifyClientId) {
    toast('Spotify no está configurado en el servidor', { error: true });
    return;
  }
  const verifier = randomString(64);
  const state = randomString(24);
  try {
    localStorage.setItem(PKCE_KEY, JSON.stringify({ verifier, state, purpose, at: Date.now() }));
  } catch {
    toast('No pude guardar el inicio de sesión: revisa que no estés en modo privado', { error: true });
    return;
  }
  const q = new URLSearchParams({
    client_id: spotifyClientId,
    response_type: 'code',
    redirect_uri: spotifyRedirect(),
    scope: (purpose === 'phone' ? SPOTIFY_SCOPES : PROJECTOR_SCOPES).join(' '),
    code_challenge_method: 'S256',
    code_challenge: await challengeOf(verifier),
    state,
  });
  location.assign(`https://accounts.spotify.com/authorize?${q}`);
}

async function tokenRequest(form) {
  const res = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(form),
  });
  const text = await res.text();
  if (!res.ok) {
    const err = new Error(`Spotify token ${res.status}: ${text.slice(0, 120)}`);
    err.status = res.status;
    throw err;
  }
  const t = JSON.parse(text);
  // Milliseconds, like the app: the projector reads the same field.
  t.expires_at = Date.now() + Math.round((t.expires_in || 3600) * 1000);
  return t;
}

/// Back from Spotify (?code=…&state=…). Returns true if this load was one.
async function spotifyCallback() {
  const q = new URLSearchParams(location.search);
  if (!q.has('code') && !q.has('error')) return false;
  history.replaceState(null, '', location.pathname);
  let pkce = null;
  try {
    pkce = JSON.parse(localStorage.getItem(PKCE_KEY) || 'null');
    localStorage.removeItem(PKCE_KEY);
  } catch {
    // Handled below.
  }
  if (q.get('error')) {
    toast(`Spotify no dio acceso: ${q.get('error')}`, { error: true });
    return true;
  }
  if (!pkce || pkce.state !== q.get('state')) {
    toast('El inicio de sesión de Spotify no coincide: intenta otra vez', { error: true });
    return true;
  }
  let token;
  try {
    token = await tokenRequest({
      grant_type: 'authorization_code',
      code: q.get('code'),
      redirect_uri: spotifyRedirect(),
      client_id: spotifyClientId,
      code_verifier: pkce.verifier,
    });
  } catch (e) {
    toast(e.message, { error: true });
    return true;
  }
  if (pkce.purpose === 'phone') {
    saveSpotifyToken(token);
    toast('Spotify conectado');
    pollSpotify();
    return true;
  }
  const pid = String(pkce.purpose || '').replace(/^link:/, '');
  const p = store.projectors.find((x) => x.id === pid);
  if (!p) {
    toast('Esa pantalla ya no está en la lista', { error: true });
    return true;
  }
  const r = await api(p, 'spotify', { method: 'POST', body: { link: { clientId: spotifyClientId, token } } });
  if (r.status === 200 && r.data.ok) {
    if (p === current() && health) health.spotify = { linked: !!r.data.linked, following: !!r.data.following };
    toast(`${p.name} ya sigue a Spotify por su cuenta`);
  } else {
    toast(errorText(r, p), { error: true });
  }
  render();
  return true;
}

async function accessToken() {
  const t = spToken;
  if (!t) throw new Error('Sin sesión de Spotify');
  if (Date.now() < (t.expires_at || 0) - 60000) return t.access_token;
  try {
    const fresh = await tokenRequest({ grant_type: 'refresh_token', refresh_token: t.refresh_token, client_id: spotifyClientId });
    // Spotify may rotate the refresh token; keep the old one if it does not.
    saveSpotifyToken({ ...t, ...fresh });
    return spToken.access_token;
  } catch (e) {
    if (e.status === 400 || e.status === 401) dropSpotify();
    throw e;
  }
}

async function sp(path, { method = 'GET', body } = {}) {
  const at = await accessToken();
  const res = await fetch(`https://api.spotify.com/v1${path}`, {
    method,
    headers: { authorization: `Bearer ${at}`, ...(body ? { 'content-type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (res.status === 401) {
    dropSpotify();
    render();
    throw new Error('Sin sesión de Spotify');
  }
  return res;
}

// --- Now playing and playback --------------------------------------------------

async function nowPlaying() {
  const res = await sp('/me/player/currently-playing');
  if (res.status === 204) return null;
  if (!res.ok) throw new Error(`Spotify ${res.status}`);
  const j = await res.json().catch(() => null);
  if (!j || !j.item || j.currently_playing_type !== 'track') return null;
  const images = (j.item.album && j.item.album.images) || [];
  return {
    uri: j.item.uri || null,
    title: j.item.name || '',
    artists: (j.item.artists || []).map((a) => a.name).filter(Boolean),
    isPlaying: !!j.is_playing,
    artUrl: images.length ? images[0].url : null,
  };
}

async function spCommand(method, path) {
  const res = await sp(path, { method });
  if (res.ok || res.status === 204) return;
  const text = await res.text().catch(() => '');
  if (res.status === 403) {
    if (text.includes('PREMIUM_REQUIRED')) throw new Error('Spotify solo deja saltar o pausar con Premium');
    return; // e.g. pausing something already paused
  }
  if (res.status === 404) throw new Error('Spotify no tiene un dispositivo activo: abre Spotify y dale play');
  throw new Error(`Spotify ${res.status}: ${text.slice(0, 120)}`);
}

let spPolling = false;

async function pollSpotify() {
  if (!spToken || spPolling) return;
  spPolling = true;
  try {
    track = await nowPlaying();
    followIfChanged();
  } catch (e) {
    if (spToken) console.warn('spotify:', e.message);
  } finally {
    spPolling = false;
  }
  render();
}

// --- Modes (same rules as the app's model) -------------------------------------

function trackKey(t) {
  return t ? `${t.artists.join(', ')}|${t.title}` : null;
}

function trackLabel(t) {
  return `${t.artists.join(', ')} – ${t.title}`;
}

/// The projector follows Spotify by itself (its own token).
function screenLinked() {
  return !!(health && health.spotify && health.spotify.linked);
}

function projectorMode() {
  if (queueMode()) return 'queue';
  if (spotifyLoggedIn() && track) return 'spotify';
  return 'free';
}

function followingSpotify() {
  return screenLinked() ? !!(health.spotify && health.spotify.following) : spotifyLoggedIn() && store.autoFollow;
}

/// The projector is showing the song that plays on Spotify.
function showingTrack() {
  const m = (health && health.media) || {};
  return stateOf(current()) === 'online' && !!m.title && !!track
    && (followingSpotify() || sentKey === trackKey(track));
}

// --- Phone-side "Seguir a Spotify" (only while this page is open) -------------

let followKey;
let followPrimed = false;
let followTimer = 0;

function followIfChanged() {
  const key = trackKey(track);
  if (key === followKey) return;
  followKey = key;
  clearTimeout(followTimer);
  // The first read after opening never sends: it is what was already playing.
  if (!followPrimed) {
    followPrimed = true;
    return;
  }
  // A projector with its own token follows by itself; sending too would open
  // the video twice.
  if (screenLinked() || !store.autoFollow || !track || !track.isPlaying) return;
  followTimer = setTimeout(() => {
    if (trackKey(track) === key && !spotifyBusy && stateOf(current()) === 'online') sendTrack(track);
  }, 3000);
}

function setAutoFollow(on) {
  store.autoFollow = on;
  saveStore();
  if (!on) clearTimeout(followTimer);
  render();
}

async function setScreenFollowing(on) {
  const p = current();
  if (!p) return;
  const r = await api(p, 'spotify', { method: 'POST', body: { following: on } });
  if (r.status === 200 && r.data.ok) {
    if (health) health.spotify = { linked: !!r.data.linked, following: !!r.data.following };
  } else {
    toast(errorText(r, p), { error: true });
  }
  render();
}

async function unlinkSpotifyFromScreen(p) {
  closeSheets();
  const r = await api(p, 'spotify', { method: 'POST', body: { unlink: true } });
  if (r.status === 200 && r.data.ok) {
    if (p === current() && health) health.spotify = { linked: false, following: false };
    toast(`Spotify desvinculado de ${p.name}`);
  } else {
    toast(errorText(r, p), { error: true });
  }
  render();
}

// --- Sending the song's video ----------------------------------------------------

const ACCENTS = { á: 'a', é: 'e', í: 'i', ó: 'o', ú: 'u', ü: 'u', ñ: 'n', à: 'a', è: 'e', ì: 'i', ò: 'o', ù: 'u', ç: 'c' };

function normalize(s) {
  return Array.from(String(s || '').toLowerCase(), (ch) => ACCENTS[ch] || ch).join('');
}

/// The song's base title: without " - En Vivo", "(Live)", "- Remastered"…
function baseTitle(title) {
  return normalize(title).split(/\s+[-–]\s+|\s*[([]/)[0].trim();
}

/// Same scoring as packages/shared (scoreVideo): prefers the artist's official
/// video; punishes lyrics, covers, lives and reactions.
function scoreVideo(v, t) {
  const title = normalize(v.title);
  const channel = normalize(v.channel);
  let s = 0;
  if (/official (music )?video|video oficial/.test(title)) s += 3;
  if (channel.includes('vevo') || t.artists.some((a) => channel.includes(normalize(a)))) s += 2;
  s += title.includes(baseTitle(t.title)) ? 3 : -3;
  if (/lyric|letra/.test(title)) s -= 3;
  if (/cover|karaoke|reaction|reacci/.test(title)) s -= 5;
  if (/\blive\b|en vivo/.test(title)) s -= 2;
  if (/ - topic$/.test(channel)) s -= 1;
  return s;
}

/// Best first; stable, so on a tie YouTube's order wins.
function rankVideos(videos, t) {
  return videos
    .map((v, i) => ({ v, i, s: scoreVideo(v, t) }))
    .sort((a, b) => b.s - a.s || a.i - b.i)
    .map((x) => x.v);
}

async function searchVideos(q) {
  const res = await fetch(`api/search?q=${encodeURIComponent(q)}`, { cache: 'no-store' });
  const d = await res.json().catch(() => ({}));
  if (!res.ok || !d.ok) throw new Error(d.error || 'No pude buscar en YouTube');
  return d.results || [];
}

async function sendTrack(t) {
  const p = current();
  if (!p || !t || spotifyBusy) return;
  spotifyBusy = true;
  render();
  try {
    toast(`Buscando el video de "${trackLabel(t)}"…`);
    const first = t.artists[0] || '';
    let videos = await searchVideos(`${first} ${t.title} official video`);
    if (!videos.length) videos = await searchVideos(`${first} ${t.title}`);
    candidates = rankVideos(videos, t);
    if (!candidates.length) throw new Error(`YouTube no encontró nada para "${trackLabel(t)}"`);
    if (await play(candidates[0])) sentKey = trackKey(t);
  } catch (e) {
    toast(e.message, { error: true });
  } finally {
    spotifyBusy = false;
    render();
  }
}

// --- Transport in Spotify mode (the app moves both Spotify and the video) ----

async function spotifyToggle() {
  const playing = !!(track && track.isPlaying);
  await spCommand('PUT', playing ? '/me/player/pause' : '/me/player/play');
  if (track) track.isPlaying = !playing;
  return playing;
}

async function spotifyNext() {
  await spCommand('POST', '/me/player/next');
  const p = current();
  toast(followingSpotify() && p ? `Siguiente canción: ${p.name} cambia el video en unos segundos` : 'Siguiente canción');
  setTimeout(pollSpotify, 1200);
}

async function spotifyPause() {
  await spCommand('PUT', '/me/player/pause');
  if (track) track.isPlaying = false;
}

// --- "Me gusta": save what plays in the playlist "proyector_13" ----------------
//
// The other way round from "Enviar el video": a YouTube video that plays on
// the projector goes back to Spotify. The video's title is cleaned and looked
// up in Spotify; the user picks the right song (a mix or a full album is not
// one song) and it is added to a private playlist of their own, created the
// first time.

const SAVE_PLAYLIST = 'proyector_13';
let savePlaylistId = null;
// What was saved this visit, so the heart shows filled: likeKey() values.
const savedHere = new Set();

/// "Luis Miguel - Hasta Que Me Olvides (Video Oficial) [HD] | Warner" →
/// "Luis Miguel Hasta Que Me Olvides".
function cleanVideoTitle(title) {
  return String(title || '')
    .replace(/\[[^\]]*\]/g, ' ')
    .replace(/\(([^)]*)\)/g, (all, inner) => (/video|vídeo|oficial|official|lyric|letra|audio|en vivo|live|hd|4k|remaster|visualizer|clip/i.test(inner) ? ' ' : all))
    .replace(/\b(official (music )?video|video oficial|vídeo oficial|videoclip|official audio|audio oficial|lyrics?|con letra|letra)\b/gi, ' ')
    .replace(/\s[|•·].*$/, ' ')
    .replace(/["“”«»]/g, ' ')
    .replace(/\p{Extended_Pictographic}/gu, ' ')
    .replace(/\s+[-–—]\s+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

/// What the heart refers to right now: the Spotify song, or the video title.
function likeKey() {
  const m = (health && health.media) || {};
  if (projectorMode() === 'spotify' && track) return `u:${track.uri || trackKey(track)}`;
  return m.title ? `v:${normalize(m.title)}` : '';
}

function spotifyWriteError(status, text) {
  if (status === 403) return 'Spotify no dejó guardar: conecta Spotify otra vez para dar el permiso nuevo';
  return `Spotify ${status}: ${String(text || '').slice(0, 100)}`;
}

async function searchSpotifyTracks(q) {
  const res = await sp(`/search?type=track&limit=5&q=${encodeURIComponent(q)}`);
  if (!res.ok) throw new Error(`Spotify ${res.status}`);
  const j = await res.json();
  return ((j.tracks && j.tracks.items) || []).filter(Boolean).map((t) => {
    const images = (t.album && t.album.images) || [];
    return {
      uri: t.uri,
      title: t.name || '',
      artists: (t.artists || []).map((a) => a.name).filter(Boolean),
      album: (t.album && t.album.name) || '',
      artUrl: images.length ? images[images.length - 1].url : null,
    };
  });
}

async function ensureSavePlaylist() {
  if (savePlaylistId) return savePlaylistId;
  if (!spotifyMe) {
    const me = await sp('/me');
    if (me.ok) spotifyMe = (await me.json()).id || null;
  }
  // One of the user's own playlists, on any page of the list.
  let next = '/me/playlists?limit=50';
  while (next) {
    const res = await sp(next);
    if (!res.ok) throw new Error(`Spotify ${res.status}`);
    const j = await res.json();
    const hit = (j.items || []).find((p) => p && p.name === SAVE_PLAYLIST && p.owner && p.owner.id === spotifyMe);
    if (hit) {
      savePlaylistId = hit.id;
      return hit.id;
    }
    next = j.next ? j.next.replace('https://api.spotify.com/v1', '') : null;
  }
  const body = { name: SAVE_PLAYLIST, public: false, description: 'Canciones guardadas desde el proyector' };
  let res = await sp('/me/playlists', { method: 'POST', body });
  // Older form of the endpoint.
  if ((res.status === 404 || res.status === 405) && spotifyMe) {
    res = await sp(`/users/${encodeURIComponent(spotifyMe)}/playlists`, { method: 'POST', body });
  }
  if (!res.ok) throw new Error(spotifyWriteError(res.status, await res.text()));
  savePlaylistId = (await res.json()).id;
  playlists = null; // the Playlists tab shows it next time
  return savePlaylistId;
}

/// 'added' or 'already' (it was in the playlist).
async function addToSavePlaylist(t) {
  const id = await ensureSavePlaylist();
  playlistTracks.delete(id);
  const have = await tracksOf(id).catch(() => []);
  if (have.some((x) => x.uri && x.uri === t.uri)) return 'already';
  let res = await sp(`/playlists/${encodeURIComponent(id)}/items`, { method: 'POST', body: { uris: [t.uri] } });
  if (res.status === 404 || res.status === 405) {
    res = await sp(`/playlists/${encodeURIComponent(id)}/tracks`, { method: 'POST', body: { uris: [t.uri] } });
  }
  if (!res.ok) throw new Error(spotifyWriteError(res.status, await res.text()));
  playlistTracks.delete(id);
  return 'added';
}

let liking = false;

async function saveSong(t) {
  if (liking) return;
  liking = true;
  const key = likeKey();
  closeSheets();
  toast('Guardando en proyector_13…');
  try {
    const r = await addToSavePlaylist(t);
    if (key) savedHere.add(key);
    toast(r === 'already' ? `"${t.title}" ya estaba en proyector_13` : `Guardada en proyector_13: ${t.title}`);
  } catch (e) {
    toast(e.message, { error: true });
  } finally {
    liking = false;
    render();
  }
}

/// The heart: the Spotify song as is, or a YouTube video looked up in Spotify.
async function likeCurrent() {
  if (!spotifyLoggedIn()) {
    spotifyAuthorize('phone');
    return;
  }
  if (projectorMode() === 'spotify' && track && track.uri) {
    saveSong(track);
    return;
  }
  const m = (health && health.media) || {};
  if (!m.title) return;
  const q = cleanVideoTitle(m.title) || m.title;
  $('like-hint').textContent = 'Buscando en Spotify…';
  $('like-list').replaceChildren();
  openSheet('sheet-like');
  let found = [];
  try {
    found = await searchSpotifyTracks(q);
  } catch (e) {
    $('like-hint').textContent = e.message;
    return;
  }
  if ($('sheet-like').hidden) return;
  if (!found.length) {
    $('like-hint').textContent = `No encontré "${q}" en Spotify`;
    return;
  }
  $('like-hint').textContent = '¿Cuál es? Toca la canción para guardarla.';
  for (const t of found.slice(0, 3)) {
    const li = document.createElement('li');
    const row = document.createElement('button');
    row.type = 'button';
    row.className = 'track-row';
    row.append(cover(t.artUrl, '52px', 'i-note'));
    const tx = document.createElement('span');
    tx.className = 'pl-text';
    const b = document.createElement('b');
    b.textContent = t.title;
    const s = document.createElement('small');
    s.textContent = [t.artists.join(', '), t.album].filter(Boolean).join(' · ');
    tx.append(b, s);
    row.append(tx);
    row.addEventListener('click', () => saveSong(t));
    li.append(row);
    $('like-list').append(li);
  }
}
