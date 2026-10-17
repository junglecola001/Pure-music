'use strict';

const crypto = require('node:crypto');
const { AppError } = require('../core/errors');

// Use the SDK's protocol encryption, but own transport limits and error/log handling.
// The SDK transport has no hard timeout and logs upstream payloads, including Set-Cookie.
function createTransport(timeoutMs = 8000, fetchImpl = fetch) {
  const encrypt = require('NeteaseCloudMusicApi/util/crypto');
  return async (uri, input, options = {}) => {
    if (!/^\/api\/[a-zA-Z0-9/_-]+$/.test(uri)) throw new AppError('UPSTREAM_PATH_REJECTED', '上游接口路径非法', 500);
    const cookie = { ...options.cookie };
    const data = { ...input };
    const mode = options.crypto || 'eapi';
    if (!['weapi', 'eapi', 'api'].includes(mode)) throw new AppError('CAPABILITY_UNSUPPORTED', '不支持的上游协议', 501);
    const headers = { 'Content-Type': 'application/x-www-form-urlencoded', Referer: 'https://music.163.com/',
      'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36' };
    let target; let payload;
    if (mode === 'weapi') {
      data.csrf_token = cookie.__csrf || '';
      headers.Cookie = Object.entries(cookie).map(([k, val]) => `${encodeURIComponent(k)}=${encodeURIComponent(val)}`).join('; ');
      target = `https://music.163.com/weapi/${uri.slice(5)}`;
      payload = encrypt.weapi(data);
    } else {
      const clientHeader = { os: 'pc', appver: '3.1.17.204416', osver: 'Windows 11', channel: 'netease',
        deviceId: cookie.deviceId || crypto.randomUUID(), __csrf: cookie.__csrf || '',
        requestId: `${Date.now()}_${crypto.randomInt(1000).toString().padStart(4, '0')}` };
      if (cookie.MUSIC_U) clientHeader.MUSIC_U = cookie.MUSIC_U;
      if (cookie.MUSIC_A) clientHeader.MUSIC_A = cookie.MUSIC_A;
      headers.Cookie = Object.entries(clientHeader).map(([k, val]) => `${encodeURIComponent(k)}=${encodeURIComponent(val)}`).join('; ');
      data.e_r = false;
      data.header = clientHeader;
      target = `https://interface.music.163.com/${mode === 'eapi' ? 'eapi/' + uri.slice(5) : uri.slice(1)}`;
      payload = mode === 'eapi' ? encrypt.eapi(uri, data) : { ...data, header: JSON.stringify(clientHeader) };
    }
    let response;
    try {
      response = await fetchImpl(target, { method: 'POST', headers, body: new URLSearchParams(payload).toString(),
        redirect: 'error', signal: AbortSignal.timeout(timeoutMs) });
      if (!response.ok) throw new AppError('UPSTREAM_HTTP_ERROR', '网易云 HTTP 请求失败', 502, { upstreamStatus: response.status });
      const chunks = []; let bytes = 0;
      for await (const chunk of response.body) {
        bytes += chunk.length;
        if (bytes > 8 * 1024 * 1024) throw new AppError('UPSTREAM_RESPONSE_TOO_LARGE', '上游响应过大', 502);
        chunks.push(chunk);
      }
      let body;
      try { body = JSON.parse(Buffer.concat(chunks).toString('utf8')); }
      catch (_) { throw new AppError('UPSTREAM_INVALID_JSON', '上游返回非 JSON 数据', 502); }
      const cookies = response.headers.getSetCookie?.() || [];
      // Modules receive a compatible transport result; no payloads or cookies are logged.
      return { status: 200, body, cookie: cookies };
    } catch (err) {
      if (err instanceof AppError) throw err;
      throw new AppError(err.name === 'TimeoutError' ? 'UPSTREAM_TIMEOUT' : 'UPSTREAM_ERROR',
        err.name === 'TimeoutError' ? '网易云连接超时' : '网易云连接失败', err.name === 'TimeoutError' ? 504 : 502);
    }
  };
}

module.exports = { createTransport };
