'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { Media } = require('../src/core/media');
const { loadConfig } = require('../src/config');
const { createApp } = require('../src/app');

async function listen(server) {
  server.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  return `http://127.0.0.1:${server.address().port}`;
}
async function setup(t, handler) {
  const upstream = http.createServer(handler);
  await listen(upstream);
  const config = loadConfig({ PERSIST_COOKIE: 'false', LOG_REQUESTS: 'false', API_TOKEN: 'x'.repeat(24) });
  let lastOptions;
  const media = new Media(config, {
    lookup: async () => [{ address: '8.8.8.8', family: 4 }],
    // Only the injected test transport routes approved test CDN names to a local fake server.
    transport: (url, options, callback) => {
      lastOptions = options;
      return http.request({ hostname: '127.0.0.1', port: upstream.address().port,
        path: url.pathname, method: options.method, headers: options.headers, signal: options.signal }, callback);
    },
  });
  const app = createApp({ config, media, api: {} });
  const server = http.createServer(app);
  const base = await listen(server);
  t.after(() => Promise.all([server, upstream].map(s => new Promise(resolve => { s.closeAllConnections(); s.close(resolve); }))));
  return { media, base, options: () => lastOptions };
}

test('Fake-IP diagnostics remain actionable while refusing the connection', async () => {
  const config = loadConfig({}); let connections = 0;
  const media = new Media(config, { lookup: async () => [{ address: '198.18.1.4', family: 4 }], transport: () => { connections++; throw new Error('must not connect'); } });
  await assert.rejects(media.open('https://m1.music.126.net/song.mp3'), error => error.code === 'MEDIA_URL_REJECTED' && error.details.reason === 'fake_ip');
  const probe = await media.probe('https://m1.music.126.net/song.mp3');
  assert.deepEqual(probe, { ok: false, reason: 'fake_ip' }); assert.equal(connections, 0);
  const privateMedia = new Media(config, { lookup: async () => [{ address: '127.0.0.1', family: 4 }] });
  assert.deepEqual(await privateMedia.probe('https://m1.music.126.net/song.mp3'), { ok: false, reason: 'non_public_dns' });
});

test('proxy forwards single Range, 206 and HEAD without Bearer; never sends account cookie', async t => {
  const audio = Buffer.concat([Buffer.from('ID3'), Buffer.alloc(10000, 1)]);
  const { media, base, options } = await setup(t, (req, res) => {
    assert.equal(req.headers.cookie, undefined);
    if (req.headers.range) {
      res.writeHead(206, { 'Content-Type': 'audio/mpeg', 'Content-Range': 'bytes 0-9/10003', 'Content-Length': 10 });
      res.end(audio.subarray(0, 10));
    } else {
      res.writeHead(200, { 'Content-Type': 'audio/mpeg', 'Content-Length': audio.length }); res.end(audio);
    }
  });
  const path = media.path('https://m1.music.126.net/song.mp3');
  const res = await fetch(base + path, { headers: { Range: 'bytes=0-9' } });
  assert.equal(res.status, 206); assert.equal(res.headers.get('content-range'), 'bytes 0-9/10003');
  assert.equal((await res.arrayBuffer()).byteLength, 10);
  const head = await fetch(base + path, { method: 'HEAD' }); assert.equal(head.status, 200); assert.equal((await head.arrayBuffer()).byteLength, 0);
  assert.equal(options().agent, false);
  await new Promise((resolve, reject) => options().lookup('m1.music.126.net', {}, (err, address) => {
    if (err) return reject(err); assert.equal(address, '8.8.8.8'); resolve();
  }));
  const probe = await media.probe('https://m1.music.126.net/song.mp3'); assert.equal(probe.ok, true);
});
test('cover accepts the CDN image/jpg alias and sends canonical JPEG for GET and HEAD', async t => {
  const { media, base } = await setup(t, (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'image/jpg', 'Content-Length': 3 });
    res.end(Buffer.from([0xff, 0xd8, 0xff]));
  });
  const path = media.path('https://p1.music.126.net/cover.jpg', 'cover');
  for (const method of ['GET', 'HEAD']) {
    const response = await fetch(base + path, { method });
    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'image/jpeg');
    assert.equal((await response.arrayBuffer()).byteLength, method === 'GET' ? 3 : 0);
  }
});

test('416, invalid multi-Range and forged tickets', async t => {
  const { media, base } = await setup(t, (_req, res) => {
    res.writeHead(416, { 'Content-Range': 'bytes */100', 'Content-Length': 5 }); res.end('error');
  });
  const path = media.path('https://m1.music.126.net/song.mp3');
  const res = await fetch(base + path, { headers: { Range: 'bytes=1000-2000' } });
  assert.equal(res.status, 416); assert.equal(res.headers.get('content-range'), 'bytes */100');
  assert.equal((await res.arrayBuffer()).byteLength, 0);
  assert.equal((await fetch(base + path, { headers: { Range: 'bytes=0-1,3-4' } })).status, 416);
  assert.equal((await fetch(base + '/api/v1/media/audio?ticket=forged')).status, 403);
});
test('redirects revalidate every target and reject SSRF', async t => {
  const { media, base } = await setup(t, (_req, res) => { res.writeHead(302, { Location: 'http://127.0.0.1/admin' }); res.end(); });
  const res = await fetch(base + media.path('https://m1.music.126.net/redirect.mp3'));
  assert.equal(res.status, 400); assert.equal((await res.json()).error.code, 'MEDIA_URL_REJECTED');
});
test('redirect loop is bounded; non-image cover and HTML audio rejected', async t => {
  const { media, base } = await setup(t, (req, res) => {
    if (req.url === '/loop') { res.writeHead(302, { Location: '/loop' }); res.end(); }
    else { res.writeHead(200, { 'Content-Type': 'text/html' }); res.end('<html>error</html>'); }
  });
  assert.equal((await fetch(base + media.path('https://m1.music.126.net/loop'))).status, 502);
  assert.equal((await fetch(base + media.path('https://p1.music.126.net/cover', 'cover'))).status, 502);
  assert.equal((await fetch(base + media.path('https://m1.music.126.net/error'))).status, 502);
});
test('client disconnect cancels the upstream stream', async t => {
  let closed;
  const ended = new Promise(resolve => { closed = resolve; });
  const { media, base } = await setup(t, (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'audio/mpeg' });
    res.write(Buffer.from('ID3'));
    const timer = setInterval(() => res.write(Buffer.alloc(1000)), 10);
    res.once('close', () => { clearInterval(timer); closed(); });
  });
  const res = await fetch(base + media.path('https://m1.music.126.net/stream'));
  const reader = res.body.getReader(); await reader.read(); await reader.cancel();
  await Promise.race([ended, new Promise((_, reject) => {
    const timer = setTimeout(() => reject(new Error('Upstream was not cancelled')), 1000); timer.unref();
  })]);
});
