'use strict';

const crypto = require('node:crypto');
const { TTLCache } = require('../core/cache');
const { AppError } = require('../core/errors');

function middleware(config) {
  const limits = new TTLCache(10000);
  return (req, res, next) => {
    req.requestId = crypto.randomUUID();
    res.set({ 'X-Request-Id': req.requestId, 'X-Content-Type-Options': 'nosniff', 'Cache-Control': 'no-store' });
    if (config.logRequests) res.once('finish', () => {
      // Never log query strings, request bodies, tokens, cookies or upstream URLs.
      console.log(JSON.stringify({ requestId: req.requestId, method: req.method,
        route: req.route?.path || 'unmatched', status: res.statusCode }));
    });
    const origin = req.headers.origin;
    if (origin) {
      res.vary('Origin');
      if (!config.corsOrigins.includes(origin)) return next(new AppError('ORIGIN_FORBIDDEN', '浏览器 Origin 未获允许', 403));
      res.set({ 'Access-Control-Allow-Origin': origin, 'Access-Control-Allow-Methods': 'GET, HEAD, POST, PUT, DELETE, OPTIONS',
        'Access-Control-Allow-Headers': 'Authorization, Content-Type, Range',
        'Access-Control-Expose-Headers': 'X-Request-Id, Content-Range, Accept-Ranges', 'Access-Control-Max-Age': '600' });
    }
    if (req.method === 'OPTIONS') return res.status(204).end();
    const ip = req.socket.remoteAddress || 'unknown';
    const mediaRequest = ['/api/v1/media/tickets', '/api/v1/media/audio', '/api/v1/media/cover'].includes(req.path);
    const limitKey = `${ip}:${mediaRequest ? 'media' : 'api'}`;
    const entry = limits.get(limitKey) || { count: 0, expiresAt: Date.now() + 60000 };
    if (++entry.count > (mediaRequest ? config.mediaRateLimit : config.rateLimit)) {
      res.set('Retry-After', String(Math.max(1, Math.ceil((entry.expiresAt - Date.now()) / 1000))));
      return next(new AppError('RATE_LIMITED', '请求过于频繁', 429));
    }
    limits.set(limitKey, entry, Math.max(1, entry.expiresAt - Date.now()));
    const publicRoute = ['/api/v1/health', '/api/v1/media/audio', '/api/v1/media/cover'].includes(req.path);
    if (config.apiToken && !publicRoute) {
      const supplied = Buffer.from(req.headers.authorization || '');
      const expected = Buffer.from(`Bearer ${config.apiToken}`);
      if (supplied.length !== expected.length || !crypto.timingSafeEqual(supplied, expected)) {
        res.set('WWW-Authenticate', 'Bearer');
        return next(new AppError('UNAUTHORIZED', '需要有效的 API_TOKEN', 401));
      }
    }
    next();
  };
}
function errorHandler(err, req, res, _next) {
  if (res.headersSent) { res.destroy(); return; }
  let error = err;
  if (err.type === 'entity.parse.failed') error = new AppError('INVALID_JSON', '请求体不是有效 JSON', 400);
  if (err.type === 'entity.too.large') error = new AppError('BODY_TOO_LARGE', '请求体超过 64KB', 413);
  if (!(error instanceof AppError)) error = new AppError('INTERNAL_ERROR', '服务器内部错误', 500);
  res.status(error.status).json({ success: false, error: { code: error.code, message: error.message,
    ...(error.details ? { details: error.details } : {}) }, requestId: req.requestId });
}

module.exports = { middleware, errorHandler };
