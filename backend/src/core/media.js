'use strict';

const http = require('node:http');
const https = require('node:https');
const dns = require('node:dns/promises');
const net = require('node:net');
const crypto = require('node:crypto');
const { pipeline } = require('node:stream/promises');
const ipaddr = require('ipaddr.js');
const { AppError } = require('./errors');
const { magic } = require('./audio');

const CDN_DOMAINS = ['music.126.net', 'music.163.com'];
function publicAddress(address) {
  try {
    const ip = ipaddr.process(address);
    return ip.range() === 'unicast';
  } catch (_) { return false; }
}
function validateUrl(input) {
  let url;
  try { url = new URL(input); } catch (_) { throw new AppError('MEDIA_URL_REJECTED', '非法媒体地址', 400); }
  const host = url.hostname.toLowerCase();
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.hash || url.port ||
    net.isIP(host) || !CDN_DOMAINS.some(domain => host === domain || host.endsWith(`.${domain}`))) {
    throw new AppError('MEDIA_URL_REJECTED', '媒体地址不在网易云 CDN 白名单', 400);
  }
  return url;
}
function rangeHeader(value) {
  if (!value) return undefined;
  const match = /^bytes=(\d*)-(\d*)$/.exec(value);
  if (!match || (!match[1] && !match[2]) || (match[1] && match[2] && Number(match[1]) > Number(match[2])) ||
    [match[1], match[2]].some(v => v && !Number.isSafeInteger(Number(v))) || (!match[1] && Number(match[2]) === 0)) {
    throw new AppError('INVALID_RANGE', '只支持单个合法 bytes Range', 416);
  }
  return value;
}

class Media {
  constructor(config, options = {}) {
    this.config = config;
    this.lookup = options.lookup || dns.lookup;
    this.transport = options.transport || ((url, opts, callback) =>
      (url.protocol === 'https:' ? https : http).request(url, opts, callback));
  }
  sign(input, kind = 'audio', ttlSeconds = this.config.mediaTtlSeconds) {
    const url = validateUrl(input).toString();
    const payload = Buffer.from(JSON.stringify({ url, kind, exp: Date.now() + ttlSeconds * 1000 })).toString('base64url');
    const signature = crypto.createHmac('sha256', this.config.mediaSecret).update(payload).digest('base64url');
    return `${payload}.${signature}`;
  }
  verify(ticket, expectedKind) {
    if (typeof ticket !== 'string' || ticket.length > 12000) throw new AppError('INVALID_MEDIA_TICKET', '媒体票据无效', 403);
    const [payload, supplied, extra] = ticket.split('.');
    const expected = crypto.createHmac('sha256', this.config.mediaSecret).update(payload || '').digest();
    const actual = Buffer.from(supplied || '', 'base64url');
    if (extra !== undefined || actual.length !== expected.length || !crypto.timingSafeEqual(actual, expected)) {
      throw new AppError('INVALID_MEDIA_TICKET', '媒体票据无效', 403);
    }
    let data;
    try { data = JSON.parse(Buffer.from(payload, 'base64url')); } catch (_) { throw new AppError('INVALID_MEDIA_TICKET', '媒体票据无效', 403); }
    if (data.kind !== expectedKind || !Number.isFinite(data.exp)) throw new AppError('INVALID_MEDIA_TICKET', '媒体票据用途不符', 403);
    if (data.exp <= Date.now()) throw new AppError('MEDIA_TICKET_EXPIRED', '媒体票据已过期，请重新解析', 410);
    validateUrl(data.url);
    return data;
  }
  path(url, kind = 'audio') { return `/api/v1/media/${kind}?ticket=${encodeURIComponent(this.sign(url, kind))}`; }
  async open(input, { method = 'GET', range, signal, timeoutMs = 9000 } = {}, hops = 0) {
    const url = validateUrl(input);
    let dnsTimer;
    let records;
    try {
      records = await Promise.race([
        this.lookup(url.hostname, { all: true, verbatim: true }),
        new Promise((_, reject) => {
          dnsTimer = setTimeout(() => reject(new AppError('MEDIA_TIMEOUT', '媒体 DNS 查询超时', 504)), timeoutMs);
        }),
      ]);
    } catch (err) {
      throw err instanceof AppError ? err : new AppError('MEDIA_DNS_ERROR', '媒体域名解析失败', 502);
    } finally { clearTimeout(dnsTimer); }
    if (!Array.isArray(records) || !records.length || records.some(record => !publicAddress(record.address))) {
      const fakeIp = Array.isArray(records) && records.some(record => /^198\.(18|19)\./.test(record.address));
      throw new AppError('MEDIA_URL_REJECTED', fakeIp ? '媒体域名解析为代理 Fake-IP，请对网易云 CDN 使用真实 DNS' : '媒体域名解析到非公网地址', 400,
        { reason: fakeIp ? 'fake_ip' : 'non_public_dns' });
    }
    if (signal?.aborted) throw new AppError('MEDIA_CANCELLED', '请求已取消', 499);
    const record = records[0];
    const response = await new Promise((resolve, reject) => {
      const req = this.transport(url, {
        method, signal, agent: false,
        headers: { 'User-Agent': 'Mozilla/5.0', Referer: 'https://music.163.com/',
          'Accept-Encoding': 'identity', ...(range ? { Range: rangeHeader(range) } : {}) },
        lookup: (_host, opts, callback) => {
          if (opts?.all) callback(null, [record]);
          else callback(null, record.address, record.family);
        },
      }, res => { clearTimeout(timer); resolve(res); });
      const timer = setTimeout(() => req.destroy(new AppError('MEDIA_TIMEOUT', '媒体首包超时', 504)), timeoutMs);
      req.once('error', err => { clearTimeout(timer); reject(err instanceof AppError ? err : new AppError('MEDIA_UPSTREAM_ERROR', '媒体连接失败', 502)); });
      req.end();
    });
    if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
      response.destroy();
      if (hops >= 3 || !response.headers.location) throw new AppError('MEDIA_REDIRECT_REJECTED', '媒体重定向过多或缺少地址', 502);
      return this.open(new URL(response.headers.location, url).toString(), { method, range, signal, timeoutMs }, hops + 1);
    }
    response.setTimeout(12000, () => response.destroy(new AppError('MEDIA_TIMEOUT', '媒体流超时', 504)));
    return response;
  }
  async probe(url, timeoutMs = 2500) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let response;
    try {
      response = await this.open(url, { range: 'bytes=0-8191', signal: controller.signal, timeoutMs });
      if (![200, 206].includes(response.statusCode)) return { ok: false, reason: 'http_error', status: response.statusCode };
      const chunks = []; let size = 0;
      for await (const chunk of response) {
        chunks.push(chunk.subarray(0, 8192 - size));
        size += Math.min(chunk.length, 8192 - size);
        if (size >= 8192) break;
      }
      const format = magic(Buffer.concat(chunks));
      return { ok: Boolean(format), format, bytes: size, status: response.statusCode, ...(!format ? { reason: 'invalid_audio' } : {}) };
    } catch (error) {
      const safeDnsReason = error instanceof AppError && error.code === 'MEDIA_URL_REJECTED' && ['fake_ip', 'non_public_dns'].includes(error.details?.reason) ? error.details.reason : null;
      return { ok: false, reason: safeDnsReason || (controller.signal.aborted || error.code === 'MEDIA_TIMEOUT' ? 'timeout' : 'connection_failed') };
    }
    finally { clearTimeout(timer); response?.destroy(); controller.abort(); }
  }
  async proxy(req, res, kind) {
    const ticket = this.verify(req.query.ticket, kind);
    const range = rangeHeader(req.headers.range);
    const controller = new AbortController();
    const cancel = () => { if (!res.writableFinished) controller.abort(); };
    res.once('close', cancel);
    let upstream;
    try {
      upstream = await this.open(ticket.url, { method: req.method, range, signal: controller.signal });
      if (![200, 206, 416].includes(upstream.statusCode)) throw new AppError('MEDIA_UPSTREAM_ERROR', '网易云媒体不可用', 502);
      const upstreamType = upstream.headers['content-type'] || (kind === 'audio' ? 'application/octet-stream' : 'image/jpeg');
      // NetEase CDN also labels JPEG covers with the common image/jpg alias.
      const ct = kind === 'cover' ? upstreamType.replace(/^image\/jpg(?=;|$)/i, 'image/jpeg') : upstreamType;
      if (kind === 'cover' && upstream.statusCode !== 416 && !/^image\/(jpeg|png|webp|gif|avif)(;|$)/i.test(ct)) {
        throw new AppError('MEDIA_TYPE_REJECTED', '封面不是受支持的图片格式', 502);
      }
      if (kind === 'audio' && /(?:text\/|json|html|xml)/i.test(ct)) throw new AppError('MEDIA_TYPE_REJECTED', '上游返回的不是音频', 502);
      res.status(upstream.statusCode).set({ 'Content-Type': ct, 'Cache-Control': 'private, no-store',
        'Accept-Ranges': 'bytes', 'Cross-Origin-Resource-Policy': 'cross-origin' });
      for (const name of ['content-length', 'content-range']) {
        if (upstream.headers[name]) res.set(name, upstream.headers[name]);
      }
      if (req.method === 'HEAD' || upstream.statusCode === 416) {
        if (upstream.statusCode === 416) res.removeHeader('Content-Length');
        upstream.destroy(); res.end(); return;
      }
      await pipeline(upstream, res);
    } finally { res.removeListener('close', cancel); upstream?.destroy(); controller.abort(); }
  }
}

module.exports = { Media, publicAddress, validateUrl, rangeHeader };
