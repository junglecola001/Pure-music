'use strict';

// Print only response metadata. Never print the signed ticket or CDN URL.
const { Media } = require('../src/core/media');
const { loadConfig } = require('../src/config');

async function main() {
  const origin = process.env.MUSIC_VERIFY_ORIGIN || 'http://127.0.0.1:3000';
  const response = await fetch(`${origin}/api/v1/search?keywords=levels&limit=1`, {
    signal: AbortSignal.timeout(20000),
    headers: process.env.API_TOKEN ? { Authorization: `Bearer ${process.env.API_TOKEN}` } : {},
  });
  const payload = await response.json();
  const cover = payload.data?.items?.[0]?.cover;
  if (!response.ok || !cover) throw new Error('无法读取封面元数据');
  const media = new Media(loadConfig(process.env));
  for (const method of ['HEAD', 'GET']) {
    let upstream;
    try {
      upstream = await media.open(cover, { method });
      console.log(JSON.stringify({ method, status: upstream.statusCode, contentType: upstream.headers['content-type'] || null }));
    } catch (error) {
      console.log(JSON.stringify({ method, code: error.code || 'CHECK_FAILED' }));
      process.exitCode = 1;
    } finally { upstream?.destroy(); }
  }
}

main().catch(() => { console.error('封面诊断未完成，请确认本机后端已启动。'); process.exitCode = 1; });
