'use strict';

const m = require('../core/models');
const { AppError } = require('../core/errors');

class Library {
  constructor(client, auth, catalog) { this.client = client; this.auth = auth; this.catalog = catalog; }
  async playlists(paging, snapshot) {
    const user = await this.auth.require(snapshot);
    const b = await this.client.call('user_playlist', { uid: user.userId, ...paging }, snapshot);
    const result = m.page((b.playlist || []).map(m.playlist), b.count, paging.limit, paging.offset);
    if (typeof b.more === 'boolean') result.hasMore = b.more;
    return result;
  }
  async likes(snapshot) {
    const user = await this.auth.require(snapshot);
    const b = await this.client.call('likelist', { uid: user.userId }, snapshot);
    return { ids: (b.ids || []).map(String) };
  }
  async albumCollectionStatus(ids, maxPages, snapshot) {
    await this.auth.require(snapshot);
    const found = new Set();
    const seen = new Set();
    const limit = 100;
    const deadline = Date.now() + this.client.timeoutMs;
    let offset = 0; let exhausted = false;
    for (let page = 0; page < maxPages && found.size < ids.length; page++) {
      this.auth.assertCurrent(snapshot);
      const remaining = deadline - Date.now();
      if (remaining <= 0) break;
      const b = await this.client.call('album_sublist', { limit, offset }, snapshot, { timeoutMs: remaining });
      this.auth.assertCurrent(snapshot);
      const rows = b.data ?? b.albums;
      if (!Array.isArray(rows) || rows.length > limit || rows.some(row => !row || !/^[1-9][0-9]*$/.test(String(row.id)))) {
        throw new AppError('UPSTREAM_INCOMPLETE', '上游未返回有效收藏专辑列表', 502);
      }
      const before = seen.size;
      for (const row of rows) {
        const id = String(row.id);
        seen.add(id);
        if (ids.includes(id)) found.add(id);
      }
      offset += rows.length;
      exhausted = typeof b.hasMore === 'boolean' ? !b.hasMore :
        Number.isSafeInteger(b.count) && b.count >= 0 ? offset >= b.count : rows.length < limit;
      if (exhausted) break;
      if (!rows.length || seen.size === before) throw new AppError('UPSTREAM_INCOMPLETE', '上游专辑分页没有推进', 502);
    }
    this.auth.assertCurrent(snapshot);
    return { ids, collected: Object.fromEntries(ids.map(id => [id, found.has(id) ? true : exhausted ? false : null])),
      complete: exhausted || found.size === ids.length, scanned: offset, nextOffset: exhausted ? null : offset };
  }
  async write(method, params, snapshot) {
    await this.auth.require(snapshot);
    if (snapshot.revision !== this.auth.store.revision) {
      throw new AppError('SESSION_CHANGED', '登录状态已变更，操作未发送', 409);
    }
    const b = await this.client.call(method, params, snapshot);
    // playlist_tracks wraps the transport result inside body in this SDK release.
    const result = b.body || b;
    if (Number(result.code ?? 200) !== 200) {
      throw new AppError('UPSTREAM_REJECTED', '网易云拒绝了此操作', 502, { upstreamCode: result.code });
    }
    if (snapshot.revision !== this.auth.store.revision) {
      throw new AppError('SESSION_CHANGED_AFTER_WRITE', '操作期间账号发生变更；请核对原账号结果，不要自动重试', 409);
    }
    this.catalog.clear();
    return result;
  }
  async like(id, liked, snapshot) {
    await this.write('like', { id, like: liked }, snapshot);
    return { id, liked };
  }
  async createPlaylist(name, isPrivate, snapshot) {
    const b = await this.write('playlist_create', { name, privacy: isPrivate ? 10 : 0 }, snapshot);
    if (!b.playlist?.id) throw new AppError('UPSTREAM_INCOMPLETE', '上游未返回创建的歌单', 502);
    return m.playlist(b.playlist);
  }
  async tracks(id, ids, operation, snapshot) {
    await this.write('playlist_tracks', { pid: id, tracks: ids.join(','), op: operation }, snapshot);
    return { id, ids, operation, accepted: true };
  }
  async collect(kind, id, collected, snapshot) {
    await this.write(kind === 'playlist' ? 'playlist_subscribe' : 'album_sub', { id, t: collected ? 1 : 2 }, snapshot);
    return { id, collected };
  }
  async comment(id, content, snapshot) {
    const b = await this.write('comment', { t: 1, type: 0, id, content }, snapshot);
    if (!b.comment) throw new AppError('UPSTREAM_INCOMPLETE', '上游未返回发表的评论，请核对后再重试', 502);
    return m.comment(b.comment);
  }
  async likeComment(id, commentId, liked, snapshot) {
    await this.write('comment_like', { type: 0, id, cid: commentId, t: liked ? 1 : 0 }, snapshot);
    return { id, commentId, liked };
  }
  async listen(id, sourceId, seconds, snapshot) {
    await this.write('scrobble', { id, sourceid: sourceId, time: seconds }, snapshot);
    return { id, seconds, platformSubmitted: true, accountDurationSync: 'unverified' };
  }
}

module.exports = { Library };
