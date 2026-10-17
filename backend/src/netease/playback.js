'use strict';

const { TTLCache } = require('../core/cache');
const { candidates, actualLevel } = require('../core/audio');
const { AppError } = require('../core/errors');

function normalized(value) { return value.normalize('NFKC').toLowerCase().replace(/[\s\p{P}]/gu, ''); }
function versions(value) {
  return [/live|现场|演唱会/i, /cover|翻唱/i, /remix|\bmix\b/i, /remaster|重制/i,
    /version|版本|重录/i, /instrumental|伴奏/i, /acoustic|不插电/i, /sped|slowed|加速|慢速|demo|dj/i]
    .map(rule => rule.test(value)).join(',');
}
function sameTrack(left, right) {
  // Metadata similarity is not an audio fingerprint; disclose every replacement.
  const names = song => song.artists.map(a => a.id || normalized(a.name)).sort().join('|');
  return left.id !== right.id && normalized(left.name) === normalized(right.name) &&
    versions(left.name) === versions(right.name) && left.artists.length > 0 && names(left) === names(right) &&
    left.durationMs > 0 && right.durationMs > 0 && Math.abs(left.durationMs - right.durationMs) <= 600;
}
function restriction(data, loggedIn) {
  if (data?.freeTrialInfo) return { code: 'TRIAL_ONLY', message: '上游仅提供试听片段', action: loggedIn ? 'check_entitlement' : 'login' };
  if (Number(data?.code) === 404) return { code: 'COPYRIGHT_UNAVAILABLE', message: '上游未提供该曲版权音源', action: 'none' };
  if (Number(data?.fee) > 0) return { code: 'ENTITLEMENT_REQUIRED', message: '此歌曲需要账号权限或购买', action: loggedIn ? 'check_entitlement' : 'login' };
  return { code: 'URL_UNAVAILABLE', message: '上游未提供可播放的音源', action: 'retry' };
}

class Playback {
  constructor(client, catalog, media, config) {
    this.client = client; this.catalog = catalog; this.media = media; this.config = config;
    this.cache = new TTLCache(200);
  }
  async direct(id, requestedQuality, snapshot, deadline) {
    let trial; let last; let failure;
    const probes = new Map();
    for (const q of candidates(requestedQuality)) {
      if (deadline - Date.now() < 150) break;
      try {
        let b; let legacy = false;
        const timeout = () => Math.min(this.config.upstreamTimeoutMs, Math.max(1, deadline - Date.now()));
        try { b = await this.client.call('song_url_v1', { id, level: q.level }, snapshot, { timeoutMs: timeout() }); }
        catch (err) {
          if (deadline - Date.now() < 150) throw err;
          legacy = true;
          b = await this.client.call('song_url', { id, br: q.bitrate }, snapshot, { timeoutMs: timeout() });
        }
        const data = b.data?.[0];
        if (data) last = data;
        if (!data?.url) continue;
        let probe = { ok: true, verified: false };
        if (this.config.probeAudio) {
          if (!probes.has(data.url)) probes.set(data.url, await this.media.probe(data.url, Math.min(2500, Math.max(1, deadline - Date.now()))));
          probe = { ...probes.get(data.url), verified: true };
        }
        if (!probe.ok) {
          const messages = {
            fake_ip: '音源域名被解析为代理 Fake-IP，请在代理中对网易云 CDN 使用真实 DNS',
            non_public_dns: '音源域名解析到非公网地址，媒体连接已被拒绝',
            timeout: '音频连接超时，请检查网络后重试',
            invalid_audio: '音源返回的内容不是受支持的音频',
            http_error: '音源服务器拒绝了音频请求，请稍后重试',
            connection_failed: '无法连接音源服务器，请检查网络后重试',
          };
          const reason = Object.hasOwn(messages, probe.reason) ? probe.reason : 'unknown';
          failure = new AppError('AUDIO_PROBE_FAILED', messages[reason] || '音频验证失败', 502, { reason }); continue;
        }
        const expiresIn = Math.min(this.config.mediaTtlSeconds, Number(data.expi) > 0 ? Number(data.expi) : this.config.mediaTtlSeconds);
        const result = { id, requestedId: id, resolvedId: id, status: data.freeTrialInfo ? 'trial' : 'full',
          playable: true, trial: Boolean(data.freeTrialInfo), url: data.url,
          requestedQuality, quality: actualLevel(data, legacy), bitrate: Number(data.br) || null,
          format: data.type || probe.format || null, size: Number(data.size) || null,
          expiresAt: Date.now() + expiresIn * 1000, verified: probe.verified,
          trialInfo: data.freeTrialInfo || null,
          restriction: data.freeTrialInfo ? restriction(data, Boolean(snapshot.cookie)) : null,
          matched: false };
        // Validate CDN URL even when probing is disabled.
        this.media.sign(result.url, 'audio', Math.max(1, expiresIn));
        if (!result.trial) return result;
        trial ||= result;
      } catch (err) { failure = err; }
    }
    if (trial) return trial;
    if (failure?.code === 'AUDIO_PROBE_FAILED' || (!last && failure)) throw failure;
    return { id, requestedId: id, resolvedId: id, status: 'unavailable', playable: false, trial: false,
      url: null, requestedQuality, quality: null, restriction: restriction(last, Boolean(snapshot.cookie)),
      matched: false, verificationFailed: failure?.code === 'AUDIO_PROBE_FAILED' };
  }
  async resolve(id, requestedQuality, allowMatch, snapshot) {
    const key = JSON.stringify([snapshot.revision, id, requestedQuality, allowMatch]);
    let result = this.cache.get(key);
    if (result?.expiresAt && result.expiresAt <= Date.now() + 5000) result = undefined;
    if (!result) {
      const deadline = Date.now() + this.config.playbackBudgetMs;
      // Reserve some of the same total budget for explicitly requested matching.
      result = await this.direct(id, requestedQuality, snapshot, allowMatch ? Date.now() + this.config.playbackBudgetMs / 2 : deadline);
      if (allowMatch && result.status !== 'full' && deadline - Date.now() > 1000) {
        try {
          const { withTimeout } = require('./client');
          const source = await withTimeout(this.catalog.detail(id, snapshot), Math.max(1, deadline - Date.now()));
          const search = await withTimeout(this.catalog.search(`${source.name} ${source.artist}`, { limit: 15, offset: 0 }, snapshot), Math.max(1, deadline - Date.now()));
          for (const candidate of search.items.filter(s => sameTrack(source, s)).slice(0, 2)) {
            if (deadline - Date.now() < 150) break;
            const alternative = await this.direct(candidate.id, requestedQuality, snapshot, deadline);
            if (alternative.status === 'full') {
              result = { ...alternative, requestedId: id, resolvedId: candidate.id, matched: true,
                matchBasis: 'metadata_not_fingerprint', matchedSong: candidate, originalRestriction: result.restriction };
              break;
            }
          }
        } catch (_) { /* Keep the original result when optional matching fails. */ }
      }
      const ttl = result.url ? Math.min(30000, Math.max(1, result.expiresAt - Date.now() - 5000)) : 5000;
      this.cache.set(key, result, ttl);
    }
    if (!result.url) return { ...result, proxyUrl: null };
    const remaining = Math.max(1, Math.floor((result.expiresAt - Date.now()) / 1000));
    return { ...result, proxyUrl: `/api/v1/media/audio?ticket=${encodeURIComponent(this.media.sign(result.url, 'audio', remaining))}` };
  }
  clear() { this.cache.clear(); }
}

module.exports = { Playback, sameTrack, restriction };
