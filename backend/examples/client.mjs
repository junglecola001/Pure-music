#!/usr/bin/env node
'use strict';

// Minimal dependency-free client for the NetEase API backend.
//
// Usage:
//   node examples/client.mjs "晴天"
//
// Environment:
//   MUSIC_API       backend origin, default http://127.0.0.1:3000
//   MUSIC_TOKEN     Bearer token, required when the backend sets API_TOKEN
//   NETEASE_COOKIE  optional; imports a NetEase cookie before querying
//   MUSIC_KEYWORD   fallback keyword when no argument is given
//
// It searches, resolves playback, reads lyrics and signs a cover ticket.
// Importing a cookie is the only account-changing call and runs only when
// NETEASE_COOKIE is set; all other calls are read-only.

const base = (process.env.MUSIC_API || 'http://127.0.0.1:3000').replace(/\/+$/, '');
const token = (process.env.MUSIC_TOKEN || '').trim();
const keyword = process.argv.slice(2).find(arg => !arg.startsWith('--')) || process.env.MUSIC_KEYWORD || '晴天';
const qualityArg = process.argv.find(arg => arg.startsWith('--quality='));
const quality = qualityArg ? qualityArg.slice('--quality='.length) : 'exhigh';

async function api(path, init = {}) {
  const headers = { ...init.headers };
  if (token) headers.Authorization = `Bearer ${token}`;
  if (init.body) headers['Content-Type'] = 'application/json';
  const response = await fetch(`${base}/api/v1${path}`, { ...init, headers });
  const text = await response.text();
  let payload;
  try { payload = JSON.parse(text); } catch { throw new Error(`HTTP ${response.status}: ${text.slice(0, 200)}`); }
  if (!response.ok || !payload.success) {
    throw new Error(`${payload.error?.code || response.status}: ${payload.error?.message || text.slice(0, 200)}`);
  }
  return payload.data;
}

function log(title, value) {
  console.log(`\n== ${title} ==`);
  console.log(typeof value === 'string' ? value : JSON.stringify(value, null, 2));
}

try {
  log('health', await api('/health'));

  if (process.env.NETEASE_COOKIE) {
    const account = await api('/auth/cookie', { method: 'POST', body: JSON.stringify({ cookie: process.env.NETEASE_COOKIE }) });
    log('account', { userId: account.userId, nickname: account.nickname, membership: account.membership });
  } else {
    log('account', 'not logged in: set NETEASE_COOKIE to import an account; public catalog and lyrics work without login');
  }

  const results = await api(`/search?keywords=${encodeURIComponent(keyword)}&limit=5`);
  log('search', { keyword, total: results.total, items: results.items.map(({ id, name, artist }) => ({ id, name, artist })) });
  const track = results.items[0];
  if (!track) throw new Error(`no result for "${keyword}"`);

  const playback = await api(`/songs/${track.id}/playback?quality=${encodeURIComponent(quality)}`);
  log('playback', {
    id: playback.id, status: playback.status, playable: playback.playable, trial: playback.trial,
    quality: playback.quality, bitrate: playback.bitrate, verified: playback.verified,
    restriction: playback.restriction, proxyUrl: playback.proxyUrl ? new URL(playback.proxyUrl, base).href : null,
    upstreamUrl: playback.url ? '<hidden: play through proxyUrl, do not store>' : null,
  });

  const lyrics = await api(`/songs/${track.id}/lyrics`);
  log('lyrics', { id: lyrics.id, instrumental: lyrics.instrumental, firstLines: (lyrics.lines || []).slice(0, 8) });

  if (track.cover) {
    const ticket = await api('/media/tickets', { method: 'POST', body: JSON.stringify({ url: track.cover, kind: 'cover' }) });
    const coverUrl = new URL(ticket.proxyUrl, base).href;
    const head = await fetch(coverUrl, { method: 'HEAD' });
    log('cover', { proxyUrl: coverUrl, status: head.status, contentType: head.headers.get('content-type') });
  }

  if (playback.playable && playback.proxyUrl) {
    const audioUrl = new URL(playback.proxyUrl, base).href;
    const head = await fetch(audioUrl, { method: 'HEAD', headers: { Range: 'bytes=0-1023' } });
    log('audio', { proxyUrl: audioUrl, status: head.status, contentRange: head.headers.get('content-range') });
  }
} catch (error) {
  console.error(`\nRequest failed: ${error.message}`);
  console.error('错误码与恢复建议见仓库 docs/API.md 的「错误码」章节。');
  process.exitCode = 1;
}
