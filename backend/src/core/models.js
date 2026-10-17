'use strict';

const id = value => value == null ? '' : String(value);
const number = value => Number.isFinite(Number(value)) ? Number(value) : 0;
function artists(raw = []) {
  return raw.map(a => ({ id: id(a.id), name: a.name || '' })).filter(a => a.name);
}
function song(raw = {}) {
  const list = artists(raw.ar || raw.artists || []);
  const al = raw.al || raw.album || {};
  return {
    provider: 'netease', id: id(raw.id), name: raw.name || '',
    artist: list.map(a => a.name).join(' / '), artists: list,
    album: { id: id(al.id), name: al.name || '', cover: al.picUrl || al.coverUrl || '' },
    cover: al.picUrl || al.coverUrl || '', durationMs: number(raw.dt ?? raw.duration),
    fee: number(raw.fee), popularity: number(raw.pop || raw.popularity),
  };
}
function playlist(raw = {}) {
  return {
    provider: 'netease', id: id(raw.id), name: raw.name || '',
    cover: raw.coverImgUrl || raw.picUrl || '', description: raw.description || '',
    trackCount: number(raw.trackCount), playCount: number(raw.playCount),
    creator: { id: id(raw.creator?.userId), name: raw.creator?.nickname || '' },
    subscribed: Boolean(raw.subscribed),
  };
}
function comment(raw = {}) {
  return {
    id: id(raw.commentId), content: raw.content || '', likedCount: number(raw.likedCount),
    liked: Boolean(raw.liked), time: number(raw.time),
    user: { id: id(raw.user?.userId), nickname: raw.user?.nickname || '', avatar: raw.user?.avatarUrl || '' },
  };
}
function radio(raw = {}) {
  return {
    id: id(raw.id), name: raw.name || '', cover: raw.picUrl || '',
    description: raw.desc || '', category: raw.category || '', programCount: number(raw.programCount),
    creator: { id: id(raw.dj?.userId), name: raw.dj?.nickname || '' },
  };
}
function program(raw = {}) {
  return { id: id(raw.id), name: raw.name || '', cover: raw.coverUrl || '',
    description: raw.description || '', durationMs: number(raw.duration),
    song: song(raw.mainSong), radio: radio(raw.radio), publishedAt: number(raw.createTime) };
}
function page(items, total, limit, offset, span = items.length) {
  const known = total !== undefined && total !== null && Number.isFinite(Number(total));
  return { items, total: known ? Number(total) : null, limit, offset,
    nextOffset: offset + span, hasMore: known ? offset + span < Number(total) : span >= limit };
}
function parseLrc(text = '') {
  const lines = [];
  const offset = Number(/\[offset:([+-]?\d+)\]/i.exec(text)?.[1] || 0);
  for (const raw of text.split(/\r?\n/)) {
    const tags = [...raw.matchAll(/\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]/g)];
    const content = raw.replace(/\[[^\]]*\]/g, '').trim();
    for (const tag of tags) {
      const timeMs = Number(tag[1]) * 60000 + Number(tag[2]) * 1000 + Number((tag[3] || '').padEnd(3, '0')) + offset;
      lines.push({ timeMs: Math.max(0, timeMs), text: content });
    }
  }
  return lines.sort((a, b) => a.timeMs - b.timeMs);
}

module.exports = { id, number, artists, song, playlist, comment, radio, program, page, parseLrc };
