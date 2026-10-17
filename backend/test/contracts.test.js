'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { loadConfig } = require('../src/config');
const { defineRoutes } = require('../src/http/routes');
const { openapi } = require('../src/http/openapi');
const fs = require('node:fs');
const path = require('node:path');
const wrap = body => ({ body: { code: 200, ...body } });
const raw = { id: 1, name: 'Song', dt: 1000, ar: [{ id: 10, name: 'Artist' }], al: { id: 20, name: 'Album' } };

async function fixture(t, overrides = {}) {
  const calls = [];
  const api = Object.fromEntries(['like', 'playlist_tracks', 'playlist_subscribe', 'album_sub', 'comment_like', 'scrobble']
    .map(name => [name, async p => { calls.push({ name, p }); return wrap({}); }]));
  Object.assign(api, {
    login_status: async () => wrap({ data: { profile: { userId: 99 }, account: { id: 99 } } }),
    user_playlist: async () => wrap({ playlist: [{ id: 10, name: 'List' }], more: true }),
    likelist: async () => wrap({ ids: [1, 2] }),
    playlist_create: async p => { calls.push({ name: 'playlist_create', p }); return wrap({ playlist: { id: 10, name: p.name } }); },
    comment: async p => { calls.push({ name: 'comment', p }); return wrap({ comment: { commentId: 55, content: p.content } }); },
    album: async () => wrap({ album: { id: 20, name: 'Album' }, songs: [raw] }),
    artist_detail: async () => wrap({ data: { artist: { id: 10, name: 'Artist', musicSize: 1 } } }),
    artist_songs: async () => wrap({ songs: [raw], total: 1 }),
    comment_music: async () => wrap({ comments: [{ commentId: 1, content: 'Hi' }], hotComments: [{ commentId: 2, content: 'Hot' }], total: 1 }),
    personalized: async () => wrap({ result: [{ id: 10, name: 'Recommended' }] }),
    recommend_songs: async () => wrap({ data: { dailySongs: [raw] } }),
    cloudsearch: async () => wrap({ result: { djRadios: [{ id: 30, name: 'Radio' }], djRadiosCount: 1 } }),
    dj_hot: async () => wrap({ djRadios: [{ id: 30, name: 'Radio' }], count: 1 }),
    dj_detail: async () => wrap({ data: { id: 30, name: 'Radio' } }),
    dj_program: async () => wrap({ programs: [{ id: 40, name: 'Program', mainSong: raw }], count: 1 }),
    ...overrides,
  });
  const app = createApp({ config: loadConfig({ PERSIST_COOKIE: 'false', LOG_REQUESTS: 'false', PROBE_AUDIO: 'false' }), api });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const request = async (route, method = 'GET', data) => {
    const res = await fetch(`http://127.0.0.1:${server.address().port}/api/v1${route}`, { method,
      ...(data === undefined ? {} : { headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data) }) });
    return { status: res.status, body: await res.json() };
  };
  return { request, calls, app };
}

test('all account writes map validated operations to the correct upstream parameters', async t => {
  const { request, calls } = await fixture(t);
  await request('/auth/cookie', 'POST', { cookie: 'MUSIC_U=valid' });
  const operations = [
    ['/me/likes/1', 'PUT', { liked: false }, 'like', { id: '1', like: false }],
    ['/playlists', 'POST', { name: 'Private list', private: true }, 'playlist_create', { privacy: 10 }],
    ['/playlists/10/tracks', 'POST', { ids: ['1', '2'] }, 'playlist_tracks', { op: 'add', tracks: '1,2', pid: '10' }],
    ['/playlists/10/tracks', 'DELETE', { ids: ['1'] }, 'playlist_tracks', { op: 'del' }],
    ['/me/collections/playlists/10', 'PUT', { collected: false }, 'playlist_subscribe', { t: 2 }],
    ['/me/collections/albums/20', 'PUT', { collected: true }, 'album_sub', { t: 1 }],
    ['/songs/1/comments', 'POST', { content: 'Hello' }, 'comment', { t: 1, type: 0, content: 'Hello' }],
    ['/songs/1/comments/55/like', 'PUT', { liked: true }, 'comment_like', { cid: '55', t: 1 }],
    ['/listen', 'POST', { id: '1', sourceId: '0', seconds: 30 }, 'scrobble', { sourceid: '0', time: 30 }],
  ];
  for (const [route, method, body, name, params] of operations) {
    const res = await request(route, method, body); assert.equal(res.status, 200, route);
    const call = calls.at(-1); assert.equal(call.name, name);
    for (const [key, value] of Object.entries(params)) assert.equal(call.p[key], value, `${name}.${key}`);
    assert.equal(call.p.cookie, 'MUSIC_U=valid');
  }
});
test('album, artist, comments, recommendations and podcasts have normalized responses', async t => {
  const { request } = await fixture(t);
  assert.equal((await request('/albums/20')).body.data.songs[0].id, '1');
  assert.equal((await request('/artists/10')).body.data.items[0].id, '1');
  assert.equal((await request('/songs/1/comments')).body.data.hot[0].id, '2');
  assert.equal((await request('/recommendations/playlists')).body.data.items[0].id, '10');
  assert.equal((await request('/podcasts/search?keywords=radio')).body.data.items[0].id, '30');
  assert.equal((await request('/podcasts/hot')).body.data.items[0].id, '30');
  assert.equal((await request('/podcasts/30')).body.data.id, '30');
  assert.equal((await request('/podcasts/30/programs')).body.data.items[0].song.id, '1');
  await request('/auth/cookie', 'POST', { cookie: 'MUSIC_U=valid' });
  assert.deepEqual((await request('/me/likes')).body.data.ids, ['1', '2']);
  assert.equal((await request('/me/playlists')).body.data.hasMore, true);
  assert.equal((await request('/recommendations/daily')).body.data.items[0].id, '1');
});
test('QR expiration, absent cookie and unverified account do not report authorized', async t => {
  const defaults = {
    login_qr_key: async () => wrap({ data: { unikey: 'key' } }),
    login_qr_create: async () => wrap({ data: { qrimg: 'image' } }),
  };
  for (const [pollResponse, expected] of [[{ body: { code: 800 } }, 410], [{ body: { code: 803 } }, 502]]) {
    const { request } = await fixture(t, { ...defaults, login_qr_check: async () => pollResponse });
    const create = await request('/auth/qr', 'POST');
    assert.equal((await request(`/auth/qr/${create.body.data.sessionId}`)).status, expected);
  }
});
test('concurrent cookie import cannot overwrite a later logout', async t => {
  let release; let began;
  const started = new Promise(resolve => { began = resolve; });
  const pending = new Promise(resolve => { release = resolve; });
  const { request, app } = await fixture(t, { login_status: async () => {
    began(); await pending; return wrap({ data: { profile: { userId: 99 }, account: { id: 99 } } });
  } });
  const importing = request('/auth/cookie', 'POST', { cookie: 'MUSIC_U=valid' });
  await started;
  await request('/auth/logout', 'POST'); release();
  assert.equal((await importing).status, 409); assert.equal(app.locals.services.store.snapshot().cookie, '');
});
test('explicit same-track matching is disclosed and disabled by default', async t => {
  const source = { ...raw, dt: 180000 }; const alternative = { ...source, id: 2 };
  const { request } = await fixture(t, {
    song_detail: async () => wrap({ songs: [source] }),
    cloudsearch: async () => wrap({ result: { songs: [alternative], songCount: 1 } }),
    song_url_v1: async p => wrap({ data: [p.id === '1' ? { code: 404, url: null } :
      { url: 'https://m1.music.126.net/alternative.mp3', level: 'standard', br: 128000 }] }),
  });
  assert.equal((await request('/songs/1/playback?quality=standard')).body.data.status, 'unavailable');
  const match = (await request('/songs/1/playback?quality=standard&allowMatch=true')).body.data;
  assert.equal(match.matched, true); assert.equal(match.requestedId, '1'); assert.equal(match.resolvedId, '2');
  assert.equal(match.matchBasis, 'metadata_not_fingerprint');
});
test('checked-in OpenAPI stays identical to generated route contract', () => {
  const checkedIn = JSON.parse(fs.readFileSync(path.join(__dirname, '../docs/openapi.json'), 'utf8'));
  assert.deepEqual(checkedIn, JSON.parse(JSON.stringify(openapi(defineRoutes({})))));
});
