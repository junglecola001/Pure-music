'use strict';

const crypto = require('node:crypto');
const { TTLCache } = require('../core/cache');
const { normalizeCookie, cookieObject } = require('../core/credentials');
const { AppError } = require('../core/errors');
const { normalizeMembership } = require('./membership');

class Auth {
  constructor(client, store, onChange = () => {}) {
    this.client = client;
    this.store = store;
    this.onChange = onChange;
    this.cache = new TTLCache(20);
    this.membershipCache = new TTLCache(20);
    this.qr = new TTLCache(20);
  }
  async account(snapshot = this.store.snapshot()) {
    if (!snapshot.cookie) return { loggedIn: false, hasCookie: false, membership: 'unknown' };
    const key = String(snapshot.revision);
    const cached = this.cache.get(key);
    if (cached) return cached;
    const status = await this.verify(snapshot);
    return this.cache.set(key, status, 30000);
  }
  assertCurrent(snapshot) {
    if (snapshot.revision !== this.store.revision) throw new AppError('SESSION_CHANGED', '登录状态已变更，请重试查询', 409);
  }
  async status(snapshot = this.store.snapshot()) {
    this.assertCurrent(snapshot);
    const account = await this.account(snapshot);
    this.assertCurrent(snapshot);
    if (!account.loggedIn) return account;
    return { ...account, ...await this.membership(snapshot, account) };
  }
  async membership(snapshot = this.store.snapshot(), account) {
    account ||= await this.require(snapshot);
    this.assertCurrent(snapshot);
    const key = `${snapshot.revision}:${account.userId}`;
    const cached = this.membershipCache.get(key);
    if (cached) return cached;
    let result; let refreshAt; let errorCode = 'UPSTREAM_INCOMPLETE';
    for (const method of ['vip_info_v2', 'vip_info']) {
      this.assertCurrent(snapshot);
      try {
        const body = await this.client.call(method, { uid: account.userId }, snapshot);
        const normalized = normalizeMembership(body);
        if (!normalized) { errorCode = 'UPSTREAM_INCOMPLETE'; continue; }
        ({ refreshAt, ...result } = normalized);
        result.source = method;
        break;
      } catch (err) { errorCode = err.code || 'UPSTREAM_ERROR'; }
    }
    this.assertCurrent(snapshot);
    result ||= { membership: 'unknown', isVip: null, isSvip: null, expiresAt: null, source: null, errorCode };
    result.checkedAt = Date.now();
    const ttl = result.membership === 'unknown' ? 15000 : Math.min(300000,
      refreshAt ? Math.max(1, refreshAt - Date.now()) : 300000);
    return this.membershipCache.set(key, result, ttl);
  }
  async verify(snapshot) {
    const b = await this.client.call('login_status', {}, snapshot);
    const data = b.data || b;
    const profile = data.profile;
    const account = data.account;
    const loggedIn = Number(data.code ?? 200) === 200 && Boolean(profile?.userId && account?.id);
    return { loggedIn, hasCookie: Boolean(snapshot.cookie),
      userId: loggedIn ? String(profile.userId) : null,
      nickname: loggedIn ? profile.nickname || '' : '', avatar: loggedIn ? profile.avatarUrl || '' : '',
      // Do not infer current playback entitlement from a cookie or a profile badge.
      membership: 'unknown' };
  }
  async require(snapshot) {
    this.assertCurrent(snapshot);
    const info = await this.account(snapshot);
    this.assertCurrent(snapshot);
    if (!info.loggedIn) throw new AppError('LOGIN_REQUIRED', '请先登录网易云', 401);
    return info;
  }
  changed() { this.cache.clear(); this.membershipCache.clear(); this.onChange(); }
  async importCookie(input) {
    const cookie = normalizeCookie(input);
    if (!cookieObject(cookie).MUSIC_U) throw new AppError('INVALID_COOKIE', '网易云 Cookie 缺少 MUSIC_U', 400);
    const snapshot = this.store.snapshot();
    const info = await this.verify({ ...snapshot, cookie });
    if (!info.loggedIn) throw new AppError('INVALID_COOKIE', 'Cookie 无效或已过期', 401);
    this.store.replace(cookie, snapshot.revision);
    this.changed();
    return { ...info, saved: true, persisted: this.store.persist };
  }
  logout() {
    // Clear local credentials, not the user's sessions in other official clients.
    this.store.replace('');
    this.qr.clear();
    this.changed();
    return { loggedIn: false, localOnly: true };
  }
  async createQr() {
    const snapshot = this.store.snapshot();
    const keyBody = await this.client.call('login_qr_key', {}, { cookie: '' });
    const key = keyBody.data?.unikey;
    if (!key) throw new AppError('UPSTREAM_INCOMPLETE', '上游未返回二维码 key', 502);
    const image = await this.client.call('login_qr_create', { key, qrimg: true }, { cookie: '' });
    const sessionId = crypto.randomUUID();
    const expiresAt = Date.now() + 180000;
    this.qr.set(sessionId, { key, expiresAt, revision: snapshot.revision, state: 'waiting', polling: false }, 180000);
    return { sessionId, expiresAt, image: image.data?.qrimg || '', url: image.data?.qrurl || '' };
  }
  async pollQr(sessionId) {
    const session = this.qr.get(sessionId);
    if (!session) throw new AppError('QR_EXPIRED', '二维码已过期或不存在', 410);
    if (session.state === 'authorized') {
      if (session.authorizedRevision !== this.store.revision) throw new AppError('SESSION_CHANGED', '登录状态已变更', 409);
      return { state: session.state, expiresAt: session.expiresAt, account: session.account };
    }
    if (session.revision !== this.store.revision) throw new AppError('SESSION_CHANGED', '登录状态已变更，请重新创建二维码', 409);
    if (session.polling) throw new AppError('QR_POLL_BUSY', '二维码状态正在查询中', 409);
    if (session.lastPolled && Date.now() - session.lastPolled < 2000) {
      return { state: session.state, expiresAt: session.expiresAt, retryAfterMs: 2000 };
    }
    session.polling = true;
    session.lastPolled = Date.now();
    try {
      const r = await this.client.call('login_qr_check', { key: session.key }, { cookie: '' },
        { allowCodes: [800, 801, 802, 803], response: true });
      const b = r.body || r;
      const code = Number(b.code);
      if (code === 800 || Date.now() >= session.expiresAt) throw new AppError('QR_EXPIRED', '二维码已过期', 410);
      if (![801, 802, 803].includes(code)) throw new AppError('UPSTREAM_INCOMPLETE', '未知二维码状态', 502);
      session.state = code === 802 ? 'scanned' : 'waiting';
      if (code === 803) {
        const cookie = normalizeCookie(r.cookie || b.cookie);
        if (!cookieObject(cookie).MUSIC_U) throw new AppError('UPSTREAM_INCOMPLETE', '扫码成功但未取得登录凭据', 502);
        const account = await this.verify({ cookie, revision: session.revision });
        if (!account.loggedIn) throw new AppError('LOGIN_UNVERIFIED', '扫码成功但账号状态尚未验证，请重试', 502);
        this.store.replace(cookie, session.revision);
        this.changed();
        session.state = 'authorized';
        session.authorizedRevision = this.store.revision;
        session.account = account;
      }
      return { state: session.state, expiresAt: session.expiresAt, ...(session.account ? { account: session.account } : {}) };
    } finally { session.polling = false; }
  }
}

module.exports = { Auth };
