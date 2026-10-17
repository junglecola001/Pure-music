'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { loadConfig } = require('../src/config');
const { Auth } = require('../src/netease/auth');
const { normalizeMembership } = require('../src/netease/membership');
const { CredentialStore } = require('../src/core/credentials');
const { NeteaseClient } = require('../src/netease/client');
const wrap = body => ({ body: { code: 200, ...body } });
const packages = (associator = null, redplus = null, musicPackage = null) => ({ associator, redplus, musicPackage });

async function fixture(t, overrides = {}, env = {}) {
  const calls = [];
  const api = {
    login_status: async p => wrap({ data: { profile: { userId: p.cookie.includes('second') ? 100 : 99 }, account: { id: 99 } } }),
    vip_info_v2: async () => wrap({ data: packages() }),
    recommend_resource: async () => wrap({ recommend: [{ id: 10, name: 'Personal', picUrl: 'https://p1.music.126.net/a.jpg' }] }),
    album_sublist: async () => wrap({ data: [], hasMore: false }),
    album_sub: async () => wrap({}),
    ...overrides,
  };
  for (const [method, fn] of Object.entries(api)) {
    api[method] = async p => { calls.push({ method, p }); return fn(p); };
  }
  const app = createApp({ config: loadConfig({ PERSIST_COOKIE: 'false', LOG_REQUESTS: 'false', PROBE_AUDIO: 'false', ...env }), api });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => { server.closeAllConnections(); server.close(resolve); }));
  const request = async (route, method = 'GET', data, headers = {}) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}/api/v1${route}`, {
      method, headers: { ...headers, ...(data === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(data === undefined ? {} : { body: JSON.stringify(data) }),
    });
    return { status: response.status, body: await response.json() };
  };
  const login = cookie => request('/auth/cookie', 'POST', { cookie: cookie || 'MUSIC_U=first' });
  return { request, login, calls, app };
}

test('membership uses explicit packages, expiry and SVIP precedence; badges and incomplete responses stay unknown', () => {
  const now = 1800000000000;
  const vip = { expireTime: now + 2000 };
  const svip = { expireTime: now + 1000 };
  assert.equal(normalizeMembership({ data: packages(vip) }, now).membership, 'vip');
  const both = normalizeMembership({ data: packages(vip, svip) }, now);
  assert.equal(both.membership, 'svip'); assert.equal(both.isVip, true); assert.equal(both.isSvip, true);
  assert.equal(both.expiresAt, svip.expireTime); assert.equal(both.refreshAt, svip.expireTime);
  assert.equal(normalizeMembership({ data: packages(vip, svip) }, now + 1000).membership, 'vip');
  assert.equal(normalizeMembership({ data: packages(vip, svip) }, now + 2000).membership, 'none');
  assert.equal(normalizeMembership({ data: packages(null, null, vip) }, now).membership, 'vip');
  assert.equal(normalizeMembership({ data: packages({ expireTime: 0 }) }, now).membership, 'none');
  for (const data of [{ vipType: 11, isVip: true, label: 'SVIP' }, {}, { redplus: { vipLevel: 1 } },
    { redplus: { expireTime: 'bad' } }, { associator: null }, packages({ expireTime: false }),
    { code: 500, ...packages(vip) }]) assert.equal(normalizeMembership({ data }, now), null);
});

test('new account queries require login, validate IDs and respect API_TOKEN', async t => {
  const { request, login, calls } = await fixture(t);
  for (const route of ['/auth/membership', '/recommendations/personal-playlists', '/me/collections/albums/status?ids=20']) {
    assert.equal((await request(route)).status, 401);
  }
  assert.equal(calls.length, 0);
  await login();
  for (const query of ['', '?ids=0', '?ids=1&ids=2', '?ids=1&maxPages=0', '?ids=1&maxPages=21', '?ids=1&maxPages=no',
    '?ids=' + Array(101).fill('1').join(',')]) assert.equal((await request('/me/collections/albums/status' + query)).status, 400, query);
  const secured = await fixture(t, {}, { API_TOKEN: 'a'.repeat(24) });
  assert.equal((await secured.request('/auth/membership')).status, 401);
  const headers = { Authorization: `Bearer ${'a'.repeat(24)}` };
  await secured.request('/auth/cookie', 'POST', { cookie: 'MUSIC_U=first' }, headers);
  assert.equal((await secured.request('/auth/membership', 'GET', undefined, headers)).status, 200);
});

test('membership fallback, account status, cache isolation and private credentials', async t => {
  const { request, login, calls } = await fixture(t, {
    vip_info_v2: async () => wrap({ code: 500 }),
    vip_info: async p => wrap({ data: packages(null, p.uid === '99' ? { expireTime: Date.now() + 60000 } : null) }),
  });
  await login();
  const first = (await request('/auth/membership')).body.data;
  assert.equal(first.membership, 'svip'); assert.equal(first.source, 'vip_info'); assert.equal(first.isVip, true);
  assert.equal((await request('/auth/status')).body.data.membership, 'svip');
  assert.equal(calls.filter(c => c.method === 'vip_info').length, 1);
  for (const call of calls.filter(c => c.method.startsWith('vip_info'))) {
    assert.equal(call.p.uid, '99'); assert.equal(call.p.cookie, 'MUSIC_U=first');
  }
  assert.equal(JSON.stringify(first).includes('MUSIC_U'), false);
  await login('MUSIC_U=second');
  assert.equal((await request('/auth/membership')).body.data.membership, 'none');
  await request('/auth/logout', 'POST');
  assert.equal((await request('/auth/membership')).status, 401);
  assert.equal((await request('/auth/status')).body.data.membership, 'unknown');
});

test('unavailable or malformed VIP data stays unknown without blocking login and account queries', async t => {
  const { request, login } = await fixture(t, {
    vip_info_v2: async () => wrap({ data: { vipType: 11, isSvip: true } }),
    vip_info: async () => wrap({ code: 500 }),
  });
  assert.equal((await login()).status, 200);
  const result = (await request('/auth/membership')).body.data;
  assert.equal(result.membership, 'unknown'); assert.equal(result.isVip, null); assert.equal(result.isSvip, null);
  assert.equal(result.source, null); assert.equal(result.errorCode, 'UPSTREAM_REJECTED');
  assert.equal((await request('/auth/status')).body.data.loggedIn, true);
  assert.equal((await request('/recommendations/personal-playlists')).status, 200);
});

test('membership cache refreshes at package expiry and retries unknown results after a short TTL', async t => {
  const now = 1800000000000;
  t.mock.timers.enable({ apis: ['Date'], now });
  let calls = 0; let fail = false;
  const config = loadConfig({ PERSIST_COOKIE: 'false' });
  const store = new CredentialStore(config); store.replace('MUSIC_U=first');
  const client = new NeteaseClient({
    login_status: async () => wrap({ data: { profile: { userId: 99 }, account: { id: 99 } } }),
    vip_info_v2: async () => { calls++; return fail ? wrap({}) : wrap({ data: packages({ expireTime: now + 2000 }, { expireTime: now + 1000 }) }); },
  }, 1000);
  const auth = new Auth(client, store);
  assert.equal((await auth.membership()).membership, 'svip');
  await auth.membership(); assert.equal(calls, 1);
  t.mock.timers.tick(1000); assert.equal((await auth.membership()).membership, 'vip');
  t.mock.timers.tick(1000); assert.equal((await auth.membership()).membership, 'none');
  auth.changed(); fail = true;
  assert.equal((await auth.membership()).membership, 'unknown');
  const before = calls; await auth.membership(); assert.equal(calls, before);
  t.mock.timers.tick(15000); await auth.membership(); assert.equal(calls, before + 1);
});

test('private recommendations normalize playlists, cache per session and preserve upstream failures', async t => {
  const { request, login, calls } = await fixture(t, { recommend_resource: async p =>
    wrap({ recommend: [{ id: p.cookie.includes('second') ? 20 : 10, name: 'For you', picUrl: 'cover', creator: { userId: 99, nickname: 'User' } }] }) });
  await login();
  const first = (await request('/recommendations/personal-playlists')).body.data.items[0];
  assert.equal(first.id, '10'); assert.equal(first.cover, 'cover'); assert.equal(first.creator.id, '99');
  await request('/recommendations/personal-playlists'); assert.equal(calls.filter(c => c.method === 'recommend_resource').length, 1);
  await login('MUSIC_U=second');
  assert.equal((await request('/recommendations/personal-playlists')).body.data.items[0].id, '20');
  for (const [body, status] of [[{ recommend: [] }, 200], [{}, 502], [{ recommend: [{}] }, 502], [{ code: 301 }, 401]]) {
    const other = await fixture(t, { recommend_resource: async () => wrap(body) });
    await other.login(); assert.equal((await other.request('/recommendations/personal-playlists')).status, status);
  }
});

test('album collection scan paginates, distinguishes unscanned IDs and observes later writes', async t => {
  let collected = false;
  const { request, login, calls } = await fixture(t, {
    album_sublist: async p => wrap({ data: p.offset === 0 ? Array.from({ length: 100 }, (_, i) => ({ id: i + 1 })) :
      [{ id: 101 }, ...(collected ? [{ id: 999 }] : [])], hasMore: p.offset === 0 }),
    album_sub: async () => { collected = true; return wrap({}); },
  });
  await login();
  const partial = (await request('/me/collections/albums/status?ids=1,101,999&maxPages=1')).body.data;
  assert.deepEqual(partial.collected, { 1: true, 101: null, 999: null }); assert.equal(partial.complete, false);
  assert.equal(partial.nextOffset, 100);
  const full = (await request('/me/collections/albums/status?ids=1,101,999,1')).body.data;
  assert.deepEqual(full.ids, ['1', '101', '999']);
  assert.deepEqual(full.collected, { 1: true, 101: true, 999: false }); assert.equal(full.complete, true);
  assert.equal(full.nextOffset, null); assert.equal(full.scanned, 101);
  await request('/me/collections/albums/999', 'PUT', { collected: true });
  assert.equal((await request('/me/collections/albums/status?ids=999')).body.data.collected['999'], true);
  for (const call of calls.filter(c => c.method === 'album_sublist')) {
    assert.equal(call.p.limit, 100); assert.equal(call.p.cookie, 'MUSIC_U=first');
  }
});

test('album scan stops once every requested ID is found; malformed, stalled and failed pages are errors', async t => {
  const first = await fixture(t, { album_sublist: async () => wrap({ data: [{ id: 1 }], hasMore: true }) });
  await first.login();
  const result = (await first.request('/me/collections/albums/status?ids=1')).body.data;
  assert.equal(result.complete, true); assert.equal(first.calls.filter(c => c.method === 'album_sublist').length, 1);
  for (const [body, status] of [[{}, 502], [{ data: [{}] }, 502], [{ data: [], hasMore: true }, 502], [{ code: 500 }, 502]]) {
    const other = await fixture(t, { album_sublist: async () => wrap(body) });
    await other.login(); assert.equal((await other.request('/me/collections/albums/status?ids=1')).status, status);
  }
  const repeated = await fixture(t, { album_sublist: async () => wrap({ data: [{ id: 2 }], hasMore: true }) });
  await repeated.login(); assert.equal((await repeated.request('/me/collections/albums/status?ids=1')).status, 502);
});

test('logout during account queries rejects stale responses', async t => {
  for (const [method, route, body] of [
    ['vip_info_v2', '/auth/membership', { data: packages(null, { expireTime: Date.now() + 60000 }) }],
    ['recommend_resource', '/recommendations/personal-playlists', { recommend: [] }],
    ['album_sublist', '/me/collections/albums/status?ids=1', { data: [], hasMore: false }],
  ]) {
    let release; let started;
    const began = new Promise(resolve => { started = resolve; });
    const pending = new Promise(resolve => { release = resolve; });
    const { request, login } = await fixture(t, { [method]: async () => { started(); await pending; return wrap(body); } });
    await login(); const query = request(route);
    await began; await request('/auth/logout', 'POST'); release();
    assert.equal((await query).status, 409);
  }
});
