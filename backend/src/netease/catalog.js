'use strict';

const m = require('../core/models');
const { TTLCache } = require('../core/cache');
const { AppError } = require('../core/errors');

class Catalog {
  constructor(client) { this.client = client; this.cache = new TTLCache(300); }
  async cached(key, snapshot, fn, ttl = 60000) {
    key = `${snapshot.revision}:${key}`;
    const hit = this.cache.get(key);
    if (hit !== undefined) return hit;
    return this.cache.set(key, await fn(), ttl);
  }
  async search(keywords, paging, snapshot) {
    return this.cached(`search:${JSON.stringify([keywords, paging])}`, snapshot, async () => {
      const b = await this.client.call('cloudsearch', { keywords, type: 1, ...paging }, snapshot);
      const raw = b.result?.songs || [];
      const songs = raw.map(m.song);
      const missing = songs.filter(s => !s.cover).map(s => s.id);
      if (missing.length) {
        try {
          const details = await this.details(missing, snapshot);
          const byId = new Map(details.map(s => [s.id, s]));
          songs.forEach((s, i) => { if (!s.cover && byId.has(s.id)) songs[i] = byId.get(s.id); });
        } catch (_) { /* Search remains useful if optional cover backfill fails. */ }
      }
      return m.page(songs, b.result?.songCount, paging.limit, paging.offset, raw.length);
    });
  }
  async details(ids, snapshot) {
    const b = await this.client.call('song_detail', { ids: ids.join(',') }, snapshot);
    const byId = new Map((b.songs || []).map(s => [String(s.id), m.song(s)]));
    return ids.map(id => byId.get(String(id))).filter(Boolean);
  }
  async detail(id, snapshot) {
    const rows = await this.details([id], snapshot);
    if (!rows.length) throw new AppError('SONG_NOT_FOUND', '歌曲不存在', 404);
    return rows[0];
  }
  async lyric(id, snapshot) {
    return this.cached(`lyric:${id}`, snapshot, async () => {
      let b;
      try { b = await this.client.call('lyric_new', { id }, snapshot); }
      catch (_) { b = await this.client.call('lyric', { id }, snapshot); }
      const original = b.lrc?.lyric || '';
      return { id, original, translated: b.tlyric?.lyric || '', romanized: b.romalrc?.lyric || '',
        wordByWord: b.yrc?.lyric || '', lines: m.parseLrc(original), instrumental: Boolean(b.nolyric) };
    }, 300000);
  }
  async comments(id, paging, snapshot) {
    const b = await this.client.call('comment_music', { id, ...paging }, snapshot);
    return { ...m.page((b.comments || []).map(m.comment), b.total, paging.limit, paging.offset),
      hot: paging.offset === 0 ? (b.hotComments || []).map(m.comment) : [] };
  }
  async playlistRaw(id, snapshot) {
    return this.cached(`playlist:${id}`, snapshot, async () => {
      const b = await this.client.call('playlist_detail', { id }, snapshot);
      if (!b.playlist) throw new AppError('PLAYLIST_NOT_FOUND', '歌单不存在', 404);
      return b.playlist;
    });
  }
  async playlist(id, snapshot) { return m.playlist(await this.playlistRaw(id, snapshot)); }
  async tracks(id, paging, snapshot) {
    const raw = await this.playlistRaw(id, snapshot);
    const index = (raw.trackIds || []).map(t => String(t.id));
    if (!index.length && Number(raw.trackCount) > (raw.tracks || []).length) {
      throw new AppError('UPSTREAM_INCOMPLETE', '上游没有返回完整歌单索引', 502);
    }
    const ordered = index.length ? index : (raw.tracks || []).map(t => String(t.id));
    const requested = ordered.slice(paging.offset, paging.offset + paging.limit);
    const rows = requested.length ? await this.details(requested, snapshot) : [];
    const returned = new Set(rows.map(s => s.id));
    return { playlist: m.playlist(raw), ...m.page(rows, ordered.length, paging.limit, paging.offset, requested.length),
      missingIds: requested.filter(id => !returned.has(id)) };
  }
  async album(id, snapshot) {
    const b = await this.client.call('album', { id }, snapshot);
    const a = b.album;
    if (!a) throw new AppError('ALBUM_NOT_FOUND', '专辑不存在', 404);
    return { album: { id: String(a.id), name: a.name || '', cover: a.picUrl || '',
      artists: m.artists(a.artists || (a.artist ? [a.artist] : [])),
      publishedAt: m.number(a.publishTime), trackCount: m.number(a.size) }, songs: (b.songs || []).map(m.song) };
  }
  async artist(id, paging, snapshot) {
    const b = await this.client.call('artist_detail', { id }, snapshot);
    const a = b.data?.artist || b.artist;
    if (!a) throw new AppError('ARTIST_NOT_FOUND', '歌手不存在', 404);
    let list;
    try { list = await this.client.call('artist_songs', { id, order: 'hot', ...paging }, snapshot); }
    catch (err) {
      if (paging.offset !== 0) throw err;
      list = await this.client.call('artist_top_song', { id }, snapshot);
      list = { ...list, songs: (list.songs || []).slice(0, paging.limit), total: null };
    }
    return { artist: { id: String(a.id || id), name: a.name || '', avatar: a.avatar || a.cover || '',
      description: a.briefDesc || '', musicSize: m.number(a.musicSize), albumSize: m.number(a.albumSize) },
      ...m.page((list.songs || []).map(m.song), list.total ?? a.musicSize, paging.limit, paging.offset) };
  }
  async recommendations(limit, snapshot) {
    const b = await this.client.call('personalized', { limit }, snapshot);
    return { items: (b.result || []).map(m.playlist) };
  }
  async daily(snapshot) {
    const b = await this.client.call('recommend_songs', {}, snapshot);
    return { items: (b.data?.dailySongs || b.recommend || []).map(m.song) };
  }
  async personalPlaylists(snapshot) {
    return this.cached('personal-playlists', snapshot, async () => {
      const b = await this.client.call('recommend_resource', {}, snapshot);
      const rows = b.recommend ?? b.data;
      if (!Array.isArray(rows) || rows.some(row => !row || !row.id)) {
        throw new AppError('UPSTREAM_INCOMPLETE', '上游未返回有效私人推荐歌单列表', 502);
      }
      return { items: rows.map(m.playlist) };
    });
  }
  async podcastSearch(keywords, paging, snapshot) {
    const b = await this.client.call('cloudsearch', { keywords, type: 1009, ...paging }, snapshot);
    return m.page((b.result?.djRadios || []).map(m.radio), b.result?.djRadiosCount, paging.limit, paging.offset);
  }
  async podcastHot(paging, snapshot) {
    const b = await this.client.call('dj_hot', paging, snapshot);
    return m.page((b.djRadios || []).map(m.radio), b.count, paging.limit, paging.offset);
  }
  async podcast(id, snapshot) {
    const b = await this.client.call('dj_detail', { rid: id }, snapshot);
    if (!b.data) throw new AppError('PODCAST_NOT_FOUND', '播客不存在', 404);
    return m.radio(b.data);
  }
  async programs(id, paging, snapshot) {
    const b = await this.client.call('dj_program', { rid: id, ...paging, asc: false }, snapshot);
    return m.page((b.programs || []).map(m.program), b.count, paging.limit, paging.offset);
  }
  clear() { this.cache.clear(); }
}

module.exports = { Catalog };
