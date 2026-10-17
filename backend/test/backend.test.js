'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createApp } = require('../src/app');
const { loadConfig } = require('../src/config');
const { normalizeCookie, CredentialStore } = require('../src/core/credentials');
const { TTLCache } = require('../src/core/cache');
const { parseLrc } = require('../src/core/models');
const { actualLevel, magic } = require('../src/core/audio');
const { NeteaseClient } = require('../src/netease/client');
const { Media, validateUrl, publicAddress, rangeHeader } = require('../src/core/media');
const { sameTrack } = require('../src/netease/playback');

const rawSong = id => ({ id: Number(id), name: `Song ${id}`, dt: 180000,
  ar: [{ id: 10, name: 'Artist' }], al: { id: 20, name: 'Album', picUrl: 'https://p1.music.126.net/cover.jpg' } });
const response = body => ({ body: { code: 200, ...body } });
function fakeApi(overrides = {}) {
  return {
    cloudsearch: async () => response({ result: { songs: [rawSong(1)], songCount: 1 } }),
    song_detail: async p => response({ songs: p.ids.split(',').reverse().map(rawSong) }),
    song_url_v1: async () => response({ data: [{ url: 'https://m1.music.126.net/1.mp3', level: 'standard', br: 128000, expi: 60 }] }),
    login_status: async p => response({ data: { profile: p.cookie.includes('valid') ? { userId: 99, nickname: 'User' } : null,
      account: p.cookie.includes('valid') ? { id: 99 } : null } }),
    playlist_detail: async () => response({ playlist: { id: 10, name: 'List', trackCount: 3, trackIds: [{ id: 3 }, { id: 1 }, { id: 2 }] } }),
    lyric_new: async () => response({ lrc: { lyric: '[00:01.25]hello' }, tlyric: { lyric: '[00:01.25]你好' } }),
    ...overrides,
  };
}
async function fixture(t, options = {}) {
  const config = loadConfig({ PERSIST_COOKIE: 'false', LOG_REQUESTS: 'false', PROBE_AUDIO: 'false', ...options.env });
  const app = createApp({ config, api: fakeApi(options.api), media: options.media });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  const request = async (url, opts = {}) => {
    const res = await fetch(base + url, opts);
    return { status: res.status, headers: res.headers, body: await res.json() };
  };
  const json = (method, data) => ({ method, headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) });
  return { app, request, json, base };
}

test('config rejects exposed unauthenticated service and invalid settings', () => {
  assert.throws(() => loadConfig({ HOST: '0.0.0.0' }), /API_TOKEN/);
  assert.throws(() => loadConfig({ PORT: 'abc' }), /PORT/);
  assert.throws(() => loadConfig({ PROBE_AUDIO: 'yes' }), /PROBE_AUDIO/);
  assert.throws(() => loadConfig({ CORS_ORIGINS: '*' }));
  assert.equal(loadConfig({}).host, '127.0.0.1');
});
test('cookie normalization handles browser exports and removes attributes', () => {
  assert.equal(normalizeCookie([{ name: 'MUSIC_U', value: 'a=b' }, { name: 'Path', value: '/' }]), 'MUSIC_U=a=b');
  assert.equal(normalizeCookie(['MUSIC_U=valid; Path=/; HttpOnly', '__csrf=token; Secure']), 'MUSIC_U=valid; __csrf=token');
  assert.throws(() => normalizeCookie({ MUSIC_U: 'x\r\nInjected: y' }), { code: 'INVALID_COOKIE' });
});
test('atomic credentials persist, reload and clear; storage failure is reported', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'netease-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const config = { persistCookie: true, cookieFile: path.join(dir, 'cookie') };
  const store = new CredentialStore(config);
  store.replace('MUSIC_U=valid');
  assert.equal(new CredentialStore(config).snapshot().cookie, 'MUSIC_U=valid');
  assert.throws(() => store.replace('', 0), { code: 'SESSION_CHANGED' });
  store.replace('');
  assert.equal(new CredentialStore(config).snapshot().cookie, '');
  fs.mkdirSync(path.join(dir, 'blocked'));
  const blocked = new CredentialStore({ persistCookie: false, cookieFile: path.join(dir, 'blocked') });
  blocked.persist = true;
  assert.throws(() => blocked.replace('MUSIC_U=x'), { code: 'CREDENTIAL_STORAGE_FAILED' });
  assert.equal(blocked.snapshot().cookie, '');
});
test('bounded TTL cache expires entries', () => {
  let time = 0; const cache = new TTLCache(2, () => time);
  cache.set('a', 1, 10); cache.set('b', 2, 10); cache.set('c', 3, 10);
  assert.equal(cache.get('a'), undefined); time = 11; assert.equal(cache.get('b'), undefined);
});
test('LRC repeated timestamps and offsets; audio level never echoes requested hires', () => {
  assert.deepEqual(parseLrc('[offset:-50]\n[00:01.2][00:02.250]hello'), [{ timeMs: 1150, text: 'hello' }, { timeMs: 2200, text: 'hello' }]);
  assert.equal(actualLevel({ level: 'standard', br: 128000 }), 'standard');
  assert.equal(actualLevel({ br: 128000 }, true), 'standard');
  assert.equal(magic(Buffer.from('fLaCdata')), 'flac');
  assert.equal(magic(Buffer.from('<html>no audio</html>')), null);
});
test('CDN host boundaries, DNS ranges, IPv4 mapped IPv6 and Range validation', () => {
  for (const url of ['http://127.0.0.1/a', 'file:///tmp/a', 'https://music.126.net.evil.com/a',
    'https://user:pass@m1.music.126.net/a', 'https://m1.music.126.net:444/a', 'https://m1.music.126.net/a#x']) assert.throws(() => validateUrl(url));
  assert.equal(validateUrl('https://m1.music.126.net/a').hostname, 'm1.music.126.net');
  for (const ip of ['127.0.0.1', '10.1.1.1', '169.254.169.254', '::1', '::ffff:127.0.0.1', 'fd00::1', '100.64.1.1', '192.0.2.1']) assert.equal(publicAddress(ip), false, ip);
  assert.equal(publicAddress('8.8.8.8'), true);
  assert.equal(rangeHeader('bytes=-10'), 'bytes=-10');
  for (const range of ['bytes=3-2', 'bytes=0-1,3-4', 'bytes=-0', 'bytes=-', 'bytes=abc']) assert.throws(() => rangeHeader(range));
});
test('signed media tickets reject tampering, wrong use, expired tickets and private DNS', async () => {
  const config = loadConfig({}); const media = new Media(config, { lookup: async () => [{ address: '127.0.0.1', family: 4 }] });
  const ticket = media.sign('https://m1.music.126.net/a');
  assert.equal(media.verify(ticket, 'audio').kind, 'audio');
  assert.throws(() => media.verify(ticket, 'cover'), { code: 'INVALID_MEDIA_TICKET' });
  assert.throws(() => media.verify(ticket + 'x', 'audio'), { code: 'INVALID_MEDIA_TICKET' });
  assert.throws(() => media.verify(media.sign('https://m1.music.126.net/a', 'audio', -1), 'audio'), { code: 'MEDIA_TICKET_EXPIRED' });
  await assert.rejects(media.open('https://m1.music.126.net/a'), { code: 'MEDIA_URL_REJECTED' });
});
test('upstream timeout and rejected API codes become structured failures', async () => {
  const client = new NeteaseClient({ slow: () => new Promise(resolve => setTimeout(() => resolve(response({})), 80)),
    rejected: async () => response({ code: 502 }) }, 10);
  await assert.rejects(client.call('slow'), { code: 'UPSTREAM_TIMEOUT' });
  await assert.rejects(client.call('rejected'), { code: 'UPSTREAM_REJECTED' });
  await assert.rejects(client.call('missing'), { code: 'CAPABILITY_UNSUPPORTED' });
});
test('search has consistent shape, IDs are strings, errors are not HTTP 200', async t => {
  const { request } = await fixture(t);
  const result = await request('/api/v1/search?keywords=hello');
  assert.equal(result.status, 200); assert.equal(result.body.data.items[0].id, '1');
  assert.equal(result.body.data.items[0].durationMs, 180000); assert.ok(result.body.requestId);
  for (const url of ['/api/v1/search', '/api/v1/search?keywords=x&limit=no', '/api/v1/search?keywords=x&keywords=y', '/api/v1/songs/abc']) {
    assert.equal((await request(url)).status, 400);
  }
  assert.equal((await request('/api/v1/search', { method: 'POST' })).status, 405);
  assert.equal((await request('/api/qq/search')).status, 404);
});
test('playlist pagination restores upstream detail order and handles final page', async t => {
  const { request } = await fixture(t);
  const first = (await request('/api/v1/playlists/10/tracks?limit=2')).body.data;
  assert.deepEqual(first.items.map(s => s.id), ['3', '1']); assert.equal(first.nextOffset, 2); assert.equal(first.hasMore, true);
  const final = (await request('/api/v1/playlists/10/tracks?limit=2&offset=2')).body.data;
  assert.deepEqual(final.items.map(s => s.id), ['2']); assert.equal(final.hasMore, false);
});
test('actual playback quality, short-lived proxy, lyric lines and opt-in matching', async t => {
  const { request } = await fixture(t);
  const data = (await request('/api/v1/songs/1/playback?quality=hires')).body.data;
  assert.equal(data.quality, 'standard'); assert.equal(data.requestedQuality, 'hires'); assert.equal(data.matched, false);
  assert.equal(data.status, 'full'); assert.ok(data.proxyUrl.startsWith('/api/v1/media/audio?ticket='));
  assert.equal((await request('/api/v1/songs/1/lyrics')).body.data.lines[0].timeMs, 1250);
  assert.equal((await request('/api/v1/songs/1/playback?allowMatch=maybe')).status, 400);
  const left = { id: '1', name: 'Song', artists: [{ id: '2', name: 'Artist' }], durationMs: 180000 };
  assert.equal(sameTrack(left, { ...left, id: '3' }), true);
  assert.equal(sameTrack(left, { ...left, id: '3', name: 'Song live' }), false);
});
test('quality downgrade prefers full track over a trial, preserves trial if only trial is available', async t => {
  const calls = [];
  const { request } = await fixture(t, { api: { song_url_v1: async p => {
    calls.push(p.level);
    return response({ data: [{ url: `https://m1.music.126.net/${p.level}.mp3`, level: p.level, br: 128000,
      ...(p.level === 'hires' ? { freeTrialInfo: { start: 0, end: 30 } } : {}) }] });
  } } });
  const full = (await request('/api/v1/songs/1/playback')).body.data;
  assert.equal(full.status, 'full'); assert.equal(full.quality, 'lossless'); assert.deepEqual(calls, ['hires', 'lossless']);
  const trialFixture = await fixture(t, { api: { song_url_v1: async () => response({ data: [{ url: 'https://m1.music.126.net/trial.mp3', level: 'standard', freeTrialInfo: { start: 0, end: 30 } }] }) } });
  const trial = (await trialFixture.request('/api/v1/songs/1/playback')).body.data;
  assert.equal(trial.status, 'trial'); assert.equal(trial.restriction.code, 'TRIAL_ONLY');
});
test('failed audio probe is never marked playable', async t => {
  const config = loadConfig({}); const media = new Media(config); media.probe = async () => ({ ok: false });
  const { request } = await fixture(t, { env: { PROBE_AUDIO: 'true' }, media });
  assert.equal((await request('/api/v1/songs/1/playback')).status, 502);
});

test('playback exposes only a safe probe reason for Fake-IP instead of hiding DNS failure', async t => {
  const config = loadConfig({}); const media = new Media(config, { lookup: async () => [{ address: '198.19.2.3', family: 4 }] });
  const { request } = await fixture(t, { media, env: { PROBE_AUDIO: 'true' } });
  const result = await request('/api/v1/songs/1/playback?quality=exhigh');
  assert.equal(result.status, 502); assert.equal(result.body.error.code, 'AUDIO_PROBE_FAILED');
  assert.equal(result.body.error.details.reason, 'fake_ip'); assert.match(result.body.error.message, /真实 DNS/);
  assert.ok(!JSON.stringify(result.body).includes('198.19.2.3')); assert.ok(!JSON.stringify(result.body).includes('https://m1'));
});
test('Cookie import verifies first, never exposes cookie, logout clears state and cache', async t => {
  let searches = 0;
  const { request, json, app } = await fixture(t, { api: { cloudsearch: async p => {
    searches++; return response({ result: { songs: [rawSong(p.cookie ? 2 : 1)], songCount: 1 } });
  } } });
  await request('/api/v1/search?keywords=x'); await request('/api/v1/search?keywords=x'); assert.equal(searches, 1);
  assert.equal((await request('/api/v1/auth/cookie', json('POST', { cookie: 'MUSIC_U=bad' }))).status, 401);
  assert.equal(app.locals.services.store.snapshot().cookie, '');
  const login = await request('/api/v1/auth/cookie', json('POST', { cookie: 'MUSIC_U=valid' }));
  assert.equal(login.body.data.loggedIn, true); assert.equal(JSON.stringify(login.body).includes('MUSIC_U'), false);
  assert.equal((await request('/api/v1/search?keywords=x')).body.data.items[0].id, '2');
  assert.equal((await request('/api/v1/auth/logout', { method: 'GET' })).status, 405);
  await request('/api/v1/auth/logout', { method: 'POST' });
  assert.equal((await request('/api/v1/auth/status')).body.data.loggedIn, false);
  assert.equal(app.locals.services.store.snapshot().cookie, '');
});
test('account writes enforce login, required booleans and upper bounds; nested failure not successful', async t => {
  let writes = 0;
  const { request, json } = await fixture(t, { api: { like: async () => { writes++; return response({}); },
    playlist_tracks: async () => response({ body: { code: 502 } }) } });
  assert.equal((await request('/api/v1/me/likes/1', json('PUT', { liked: true }))).status, 401);
  await request('/api/v1/auth/cookie', json('POST', { cookie: 'MUSIC_U=valid' }));
  assert.equal((await request('/api/v1/me/likes/1', json('PUT', {}))).status, 400);
  assert.equal((await request('/api/v1/me/likes/1', json('PUT', { liked: true }))).status, 200); assert.equal(writes, 1);
  assert.equal((await request('/api/v1/playlists/10/tracks', json('POST', { ids: ['1'] }))).status, 502);
  assert.equal((await request('/api/v1/listen', json('POST', { id: '1' }))).status, 400);
  assert.equal((await request('/api/v1/listen', json('POST', { id: '1', seconds: 999999 }))).status, 400);
});
test('QR sessions are linked, credentials stay private and missing credentials never imply login', async t => {
  const { request } = await fixture(t, { api: {
    login_qr_key: async () => response({ data: { unikey: 'private-key' } }),
    login_qr_create: async () => response({ data: { qrimg: 'image', qrurl: 'https://music.163.com/login' } }),
    login_qr_check: async () => ({ body: { code: 803 }, cookie: ['MUSIC_U=valid; Path=/; HttpOnly'] }),
  } });
  const create = (await request('/api/v1/auth/qr', { method: 'POST' })).body.data;
  assert.equal('key' in create, false);
  const poll = await request(`/api/v1/auth/qr/${create.sessionId}`);
  assert.equal(poll.body.data.state, 'authorized'); assert.equal(JSON.stringify(poll.body).includes('MUSIC_U'), false);
  assert.equal((await request('/api/v1/auth/qr/00000000-0000-0000-0000-000000000000')).status, 410);
});
test('API_TOKEN, CORS, rate limits, malformed JSON and compatibility aliases', async t => {
  const { request } = await fixture(t, { env: { API_TOKEN: 'a'.repeat(24), CORS_ORIGINS: 'http://example.com' } });
  assert.equal((await request('/api/v1/health')).status, 200);
  assert.equal((await request('/api/v1/search?keywords=x')).status, 401);
  const headers = { Authorization: `Bearer ${'a'.repeat(24)}` };
  assert.equal((await request('/api/search?keywords=x', { headers })).status, 200);
  assert.equal((await request('/api/v1/health', { headers: { Origin: 'https://evil.com' } })).status, 403);
  const cors = await request('/api/v1/health', { headers: { Origin: 'http://example.com' } });
  assert.equal(cors.headers.get('access-control-allow-origin'), 'http://example.com');
  assert.equal((await request('/api/v1/auth/cookie', { method: 'POST', headers: { ...headers, 'Content-Type': 'application/json' }, body: '{' })).status, 400);
  const limited = await fixture(t, { env: { RATE_LIMIT_PER_MINUTE: '1' } });
  assert.equal((await limited.request('/api/v1/health')).status, 200);
  assert.equal((await limited.request('/api/v1/health')).status, 429);
});
test('media has a bounded independent budget and cannot exhaust catalog requests', async t => {
  const { request, json } = await fixture(t, { env: { RATE_LIMIT_PER_MINUTE: '1', MEDIA_RATE_LIMIT_PER_MINUTE: '2' } });
  assert.equal((await request('/api/v1/media/tickets', json('POST', { url: 'https://p1.music.126.net/cover.jpg', kind: 'cover' }))).status, 200);
  assert.equal((await request('/api/v1/media/cover?ticket=forged')).status, 403);
  const limited = await request('/api/v1/media/audio?ticket=forged');
  assert.equal(limited.status, 429);
  assert.ok(Number(limited.headers.get('retry-after')) > 0);
  assert.equal((await request('/api/v1/health')).status, 200);
  assert.equal((await request('/api/v1/health')).status, 429);
});

test('OpenAPI is generated from all live route definitions', async t => {
  const { request, app } = await fixture(t);
  const res = await request('/api/v1/openapi.json');
  assert.equal(res.body.openapi, '3.1.0');
  const { defineRoutes } = require('../src/http/routes');
  for (const route of defineRoutes(app.locals.services)) {
    const p = '/api/v1' + route.path.replace(/:(\w+)/g, '{$1}');
    assert.ok(res.body.paths[p][route.method], `${route.method} ${p}`);
  }
});
