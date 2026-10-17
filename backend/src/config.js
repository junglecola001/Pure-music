'use strict';

const path = require('node:path');
const crypto = require('node:crypto');

function loadConfig(env = process.env) {
  function integer(name, fallback, min, max) {
    const raw = env[name] ?? fallback;
    const value = Number(raw);
    if (!/^\d+$/.test(String(raw)) || !Number.isSafeInteger(value) || value < min || value > max) {
      throw new Error(`Invalid ${name}: expected integer ${min}..${max}`);
    }
    return value;
  }
  function boolean(name, fallback) {
    if (env[name] === undefined || env[name] === '') return fallback;
    if (!['true', 'false'].includes(env[name])) throw new Error(`Invalid ${name}: use true or false`);
    return env[name] === 'true';
  }
  const host = env.HOST || '127.0.0.1';
  const apiToken = env.API_TOKEN || '';
  if (apiToken && apiToken.length < 24) throw new Error('API_TOKEN must contain at least 24 characters');
  if (!['127.0.0.1', '::1', 'localhost'].includes(host) && !apiToken) {
    throw new Error('API_TOKEN is required when HOST is not loopback');
  }
  const mediaSecret = env.MEDIA_SECRET || crypto.randomBytes(32).toString('hex');
  if (mediaSecret.length < 32) throw new Error('MEDIA_SECRET must contain at least 32 characters');
  const corsOrigins = (env.CORS_ORIGINS || '').split(',').map(v => v.trim()).filter(Boolean);
  for (const origin of corsOrigins) {
    const url = new URL(origin);
    if (!['http:', 'https:'].includes(url.protocol) || url.origin !== origin) throw new Error('Invalid CORS_ORIGINS');
  }
  return Object.freeze({
    host, apiToken, mediaSecret, corsOrigins,
    port: integer('PORT', 3000, 0, 65535),
    cookieFile: path.resolve(env.COOKIE_FILE || './data/netease.cookie'),
    persistCookie: boolean('PERSIST_COOKIE', true),
    probeAudio: boolean('PROBE_AUDIO', true),
    logRequests: boolean('LOG_REQUESTS', true),
    upstreamTimeoutMs: integer('UPSTREAM_TIMEOUT_MS', 8000, 100, 60000),
    playbackBudgetMs: integer('PLAYBACK_BUDGET_MS', 15000, 100, 60000),
    mediaTtlSeconds: integer('MEDIA_TTL_SECONDS', 300, 10, 900),
    rateLimit: integer('RATE_LIMIT_PER_MINUTE', 120, 1, 10000),
    mediaRateLimit: integer('MEDIA_RATE_LIMIT_PER_MINUTE', 600, 1, 10000),
  });
}

module.exports = { loadConfig };
