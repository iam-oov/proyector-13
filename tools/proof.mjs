#!/usr/bin/env node
// Prueba de punta a punta desde la Mac, sin Flutter:
//   Spotify (qué suena) -> YouTube (video oficial) -> proyector (adb am start)
//
// Uso:
//   node tools/proof.mjs --dry-run   # solo muestra qué suena y qué video elegiría
//   node tools/proof.mjs             # además lo abre en el proyector
//
// La primera vez abre el navegador para iniciar sesión en Spotify (PKCE + loopback)
// y guarda el token en tools/.spotify-token.json (ignorado por git).

import { createServer } from 'node:http';
import { createHash, randomBytes } from 'node:crypto';
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const TOKEN_FILE = path.join(ROOT, 'tools', '.spotify-token.json');
const SCOPES = 'user-read-currently-playing user-read-playback-state';

const env = Object.fromEntries(
  readFileSync(path.join(ROOT, '.env'), 'utf8')
    .split('\n')
    .filter((l) => /^[A-Z_]+=/.test(l))
    .map((l) => {
      const i = l.indexOf('=');
      return [l.slice(0, i), l.slice(i + 1).trim()];
    }),
);

// --- Spotify: login PKCE con redirect a 127.0.0.1 ---------------------------

async function login() {
  const verifier = randomBytes(64).toString('base64url');
  const challenge = createHash('sha256').update(verifier).digest('base64url');
  const redirect = env.SPOTIFY_REDIRECT_URI;
  const authUrl = new URL('https://accounts.spotify.com/authorize');
  authUrl.search = new URLSearchParams({
    client_id: env.SPOTIFY_CLIENT_ID,
    response_type: 'code',
    redirect_uri: redirect,
    scope: SCOPES,
    code_challenge_method: 'S256',
    code_challenge: challenge,
  }).toString();

  const code = await new Promise((resolve, reject) => {
    const { port, pathname } = new URL(redirect);
    const srv = createServer((req, res) => {
      const u = new URL(req.url, redirect);
      if (u.pathname !== pathname) {
        res.writeHead(404).end();
        return;
      }
      res.end('Listo. Ya puedes cerrar esta pestaña y volver a la terminal.');
      srv.close();
      const c = u.searchParams.get('code');
      c ? resolve(c) : reject(new Error(`Spotify: ${u.searchParams.get('error')}`));
    });
    srv.listen(Number(port), '127.0.0.1', () => {
      console.log('Abriendo el navegador para iniciar sesión en Spotify…');
      execFileSync('open', [authUrl.toString()]);
    });
  });

  const tok = await tokenRequest({
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirect,
    client_id: env.SPOTIFY_CLIENT_ID,
    code_verifier: verifier,
  });
  saveToken(tok);
  return tok;
}

async function tokenRequest(params) {
  const r = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(params),
  });
  if (!r.ok) throw new Error(`Spotify token: ${r.status} ${await r.text()}`);
  const t = await r.json();
  t.expires_at = Date.now() + t.expires_in * 1000;
  return t;
}

function saveToken(t) {
  writeFileSync(TOKEN_FILE, JSON.stringify(t), { mode: 0o600 });
}

async function accessToken() {
  if (!existsSync(TOKEN_FILE)) return (await login()).access_token;
  let t = JSON.parse(readFileSync(TOKEN_FILE, 'utf8'));
  if (Date.now() > t.expires_at - 60_000) {
    const fresh = await tokenRequest({
      grant_type: 'refresh_token',
      refresh_token: t.refresh_token,
      client_id: env.SPOTIFY_CLIENT_ID,
    });
    t = { ...t, ...fresh };
    saveToken(t);
  }
  return t.access_token;
}

// --- Spotify: qué suena ------------------------------------------------------

async function nowPlaying() {
  const r = await fetch('https://api.spotify.com/v1/me/player/currently-playing', {
    headers: { authorization: `Bearer ${await accessToken()}` },
  });
  if (r.status === 204) return null;
  if (!r.ok) throw new Error(`Spotify player: ${r.status} ${await r.text()}`);
  const j = await r.json();
  if (!j.item || j.currently_playing_type !== 'track') return null;
  const artists = j.item.artists.map((a) => a.name);
  return { title: j.item.name, artists, isPlaying: j.is_playing };
}

// --- YouTube: buscar y elegir el video oficial --------------------------------

async function searchVideos(q) {
  const u = new URL('https://www.googleapis.com/youtube/v3/search');
  u.search = new URLSearchParams({
    part: 'snippet',
    type: 'video',
    videoCategoryId: '10',
    maxResults: '5',
    q,
    key: env.YOUTUBE_API_KEY,
  }).toString();
  const r = await fetch(u);
  if (!r.ok) throw new Error(`YouTube: ${r.status} ${await r.text()}`);
  const j = await r.json();
  return j.items.map((i) => ({
    id: i.id.videoId,
    title: i.snippet.title,
    channel: i.snippet.channelTitle,
  }));
}

const norm = (s) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');

// Titulo base de la cancion: sin " - En Vivo", "(Live)", "- Remastered", etc.
const baseTitle = (title) => norm(title).split(/\s+[-–]\s+|\s*[([]/)[0].trim();

// Mismo ranker que ira en packages/shared: prefiere el video oficial del artista.
function score(v, track) {
  const t = norm(v.title);
  const c = norm(v.channel);
  let s = 0;
  if (/official (music )?video|video oficial/.test(t)) s += 3;
  if (/vevo/.test(c) || track.artists.some((a) => c.includes(norm(a)))) s += 2;
  s += t.includes(baseTitle(track.title)) ? 3 : -3;
  if (/lyric/.test(t)) s -= 3;
  if (/cover|karaoke|reaction|reacci/.test(t)) s -= 5;
  if (/\blive\b|en vivo/.test(t)) s -= 2;
  if (/ - topic$/.test(c)) s -= 1;
  return s;
}

function rank(videos, track) {
  return videos.map((v) => ({ ...v, score: score(v, track) })).sort((a, b) => b.score - a.score);
}

// --- Proyector ----------------------------------------------------------------

function sendToProjector(videoId) {
  const serial = `${env.PROYECTOR_ADB_HOST}:3333`;
  execFileSync('adb', ['connect', serial], { stdio: 'ignore' });
  execFileSync(
    'adb',
    ['-s', serial, 'shell', 'am', 'start', '-a', 'android.intent.action.VIEW', '-d', `https://www.youtube.com/watch?v=${videoId}`],
    { stdio: 'ignore' },
  );
}

// --- main ----------------------------------------------------------------------

const dryRun = process.argv.includes('--dry-run');
const track = await nowPlaying();
if (!track) {
  console.log('No hay nada sonando en Spotify.');
  process.exit(0);
}
console.log(`Suena: ${track.artists.join(', ')} – ${track.title}${track.isPlaying ? '' : ' (pausado)'}`);

const ranked = rank(await searchVideos(`${track.artists[0]} ${track.title} official video`), track);
ranked.forEach((v, i) =>
  console.log(`${i === 0 ? '→' : ' '} [${String(v.score).padStart(2)}] ${v.title}  (${v.channel})  youtu.be/${v.id}`),
);
if (dryRun) process.exit(0);

sendToProjector(ranked[0].id);
console.log(`Enviado al proyector: youtu.be/${ranked[0].id}`);
