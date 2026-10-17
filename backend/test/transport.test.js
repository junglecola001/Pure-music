'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createTransport } = require('../src/netease/transport');
const { loadSdk } = require('../src/netease/sdk');

function reply(body, cookies = []) {
  const response = new Response(JSON.stringify(body), { status: 200 });
  response.headers.getSetCookie = () => cookies;
  return response;
}

test('transport uses fixed official HTTPS domains, forwards only encrypted protocol data, and exposes Set-Cookie only internally', async () => {
  const calls = [];
  const transport = createTransport(1000, async (url, options) => {
    calls.push({ url, options }); return reply({ code: 200, value: 1 }, ['MUSIC_U=valid; Path=/']);
  });
  const result = await transport('/api/song/detail', { id: '1' }, { crypto: 'eapi', cookie: { MUSIC_U: 'secret' }, domain: 'https://evil.com' });
  assert.equal(result.body.value, 1); assert.deepEqual(result.cookie, ['MUSIC_U=valid; Path=/']);
  assert.equal(calls[0].url, 'https://interface.music.163.com/eapi/song/detail');
  assert.equal(calls[0].options.redirect, 'error'); assert.match(calls[0].options.body, /^params=/);
  assert.equal(calls[0].options.body.includes('secret'), false);
  await transport('/api/playlist/create', { name: 'List' }, { crypto: 'weapi', cookie: {} });
  assert.equal(calls[1].url, 'https://music.163.com/weapi/playlist/create');
  await assert.rejects(transport('http://127.0.0.1/admin', {}, {}), { code: 'UPSTREAM_PATH_REJECTED' });
});
test('transport rejects HTTP errors, non-JSON and oversized responses without returning bodies', async () => {
  const httpError = createTransport(1000, async () => new Response('Sensitive details', { status: 500 }));
  await assert.rejects(httpError('/api/test', {}, {}), { code: 'UPSTREAM_HTTP_ERROR' });
  const invalid = createTransport(1000, async () => new Response('<html>error</html>'));
  await assert.rejects(invalid('/api/test', {}, {}), { code: 'UPSTREAM_INVALID_JSON' });
  const huge = createTransport(1000, async () => new Response('x'.repeat(8 * 1024 * 1024 + 1)));
  await assert.rejects(huge('/api/test', {}, {}), { code: 'UPSTREAM_RESPONSE_TOO_LARGE' });
});
test('transport actually supplies a cancellation deadline rather than merely racing a promise', async () => {
  const transport = createTransport(20, async (_url, options) => new Promise((_, reject) => {
    options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true });
  }));
  // Keep the test process alive: AbortSignal.timeout uses an unref timer.
  const keepalive = setTimeout(() => {}, 1000);
  try { await assert.rejects(transport('/api/test', {}, {}), { code: 'UPSTREAM_TIMEOUT' }); }
  finally { clearTimeout(keepalive); }
});
test('only explicitly selected SDK modules are loaded and protocol functions exist', () => {
  const api = loadSdk();
  assert.equal(typeof api.song_url_v1, 'function'); assert.equal(typeof api.login_qr_create, 'function');
  for (const method of ['vip_info_v2', 'vip_info', 'recommend_resource', 'album_sublist']) assert.equal(typeof api[method], 'function');
  assert.equal(api.server, undefined); assert.equal(api.avatar_upload, undefined); assert.equal(api.api, undefined);
});
