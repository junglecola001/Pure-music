'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { AppError } = require('./errors');

const ATTRIBUTES = new Set(['path', 'domain', 'expires', 'max-age', 'samesite', 'secure', 'httponly']);
function normalizeCookie(input) {
  const picked = new Map();
  function pair(name, value) {
    name = String(name || '').trim();
    if (!name || ATTRIBUTES.has(name.toLowerCase()) || value == null || typeof value === 'object') return;
    const text = String(value).trim();
    if (!/^[!#$%&'*+.^_`|~\w-]+$/.test(name) || /[\r\n;\x00-\x1f\x7f]/.test(text)) {
      throw new AppError('INVALID_COOKIE', 'Cookie 包含非法字符', 400);
    }
    if (text) picked.set(name, text);
  }
  function collect(value, depth = 0) {
    if (depth > 5) throw new AppError('INVALID_COOKIE', 'Cookie 嵌套过深', 400);
    if (Array.isArray(value)) return value.forEach(v => collect(v, depth + 1));
    if (value && typeof value === 'object') {
      if ('name' in value && 'value' in value) return pair(value.name, value.value);
      return Object.entries(value).forEach(([key, v]) => pair(key, v && typeof v === 'object' ? v.value : v));
    }
    if (typeof value !== 'string') return;
    value.split(/\r?\n/).forEach(line => line.split(';').forEach(part => {
      const index = part.indexOf('=');
      if (index > 0) pair(part.slice(0, index), part.slice(index + 1));
    }));
  }
  collect(input);
  const result = [...picked].map(([k, v]) => `${k}=${v}`).join('; ');
  if (Buffer.byteLength(result) > 32768) throw new AppError('INVALID_COOKIE', 'Cookie 过长', 400);
  return result;
}

function cookieObject(cookie) {
  return Object.fromEntries(cookie.split(';').map(part => {
    const i = part.indexOf('=');
    return [part.slice(0, i).trim(), part.slice(i + 1)];
  }).filter(([key]) => key));
}

class CredentialStore {
  constructor({ persistCookie, cookieFile }) {
    this.persist = persistCookie;
    this.file = cookieFile;
    this.cookie = '';
    this.revision = 0;
    if (this.persist) {
      try { this.cookie = normalizeCookie(fs.readFileSync(this.file, 'utf8')); }
      catch (err) { if (err.code !== 'ENOENT') throw err; }
    }
  }
  snapshot() { return Object.freeze({ cookie: this.cookie, revision: this.revision }); }
  replace(cookie, expectedRevision) {
    if (expectedRevision !== undefined && expectedRevision !== this.revision) {
      throw new AppError('SESSION_CHANGED', '登录状态已变更，请重试', 409);
    }
    const normalized = normalizeCookie(cookie);
    if (this.persist) {
      const temp = `${this.file}.${crypto.randomUUID()}.tmp`;
      try {
        fs.mkdirSync(path.dirname(this.file), { recursive: true });
        fs.writeFileSync(temp, normalized, { mode: 0o600, flag: 'wx' });
        fs.renameSync(temp, this.file);
      } catch (err) {
        try { fs.unlinkSync(temp); } catch (_) {}
        throw new AppError('CREDENTIAL_STORAGE_FAILED', '登录凭据保存失败', 500);
      }
    }
    this.cookie = normalized;
    this.revision++;
    return this.snapshot();
  }
}

module.exports = { normalizeCookie, cookieObject, CredentialStore };
