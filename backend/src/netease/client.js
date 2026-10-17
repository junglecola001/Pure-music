'use strict';

const { AppError, upstreamError } = require('../core/errors');

function withTimeout(promise, ms) {
  let timer;
  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new AppError('UPSTREAM_TIMEOUT', '上游请求超时', 504)), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

class NeteaseClient {
  constructor(api, timeoutMs) {
    this.api = api;
    this.timeoutMs = timeoutMs;
    this.active = 0;
  }
  async call(method, params = {}, snapshot = { cookie: '' }, options = {}) {
    if (typeof this.api[method] !== 'function') throw new AppError('CAPABILITY_UNSUPPORTED', '当前上游版本不支持此接口', 501);
    if (this.active >= 64) throw new AppError('UPSTREAM_BUSY', '上游请求过多，请稍后重试', 503);
    this.active++;
    // The SDK does not expose cancellation. Bound outstanding work, including timed-out calls.
    const work = Promise.resolve().then(() => this.api[method]({
      ...params, cookie: snapshot.cookie, timestamp: Date.now(),
    })).finally(() => { this.active--; });
    try {
      const response = await withTimeout(work, options.timeoutMs || this.timeoutMs);
      const body = response?.body || response;
      if (!body || typeof body !== 'object' || Array.isArray(body)) {
        throw new AppError('UPSTREAM_INCOMPLETE', '上游未返回有效响应', 502);
      }
      const code = Number(body?.code ?? body?.body?.code ?? 200);
      if (!options.allowCodes?.includes(code) && code !== 200) {
        if ([301, 401, 403].includes(code)) throw new AppError('LOGIN_REQUIRED', '网易云登录失效或没有操作权限', 401);
        throw new AppError('UPSTREAM_REJECTED', '网易云拒绝了此请求', 502, { upstreamCode: code });
      }
      return options.response ? response : body;
    } catch (err) { throw upstreamError(err); }
  }
}

module.exports = { NeteaseClient, withTimeout };
