'use strict';

const v = require('./validation');
const { quality } = require('../core/audio');
const { AppError } = require('../core/errors');

const idSchema = { type: 'string', pattern: '^[1-9][0-9]*$', maxLength: 20 };
const boolSchema = { type: 'boolean' };
const idsSchema = { type: 'array', minItems: 1, maxItems: 100, items: idSchema };
const textSchema = maxLength => ({ type: 'string', minLength: 1, maxLength });
const param = (name, schema = idSchema, required = true) => ({ name, in: 'query', required, schema });
const paged = [param('limit', { type: 'integer', minimum: 1, maximum: 100, default: 20 }, false),
  param('offset', { type: 'integer', minimum: 0, maximum: 1000000, default: 0 }, false)];
const body = (properties, required = Object.keys(properties)) => ({ type: 'object', properties, required });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function defineRoutes(s) {
  const { catalog, playback, auth, library, media, store, config } = s;
  const routes = [];
  const add = (method, path, summary, handler, options = {}) => routes.push({ method, path, summary, handler, ...options });
  const snapshot = req => req.accountSnapshot;
  const id = req => v.identifier(req.params.id);
  const b = req => v.bodyObject(req.body);
  const page = req => v.pagination(req.query);
  add('get', '/health', '进程健康检查（不代表上游在线）', () => ({ status: 'ok', version: '1.0.0', provider: 'netease' }), { public: true });
  add('get', '/capabilities', '接口能力与使用边界', () => ({ provider: 'netease', accountMode: 'single',
    catalog: ['search', 'songs', 'lyrics', 'comments', 'playlists', 'albums', 'artists', 'podcasts'],
    auth: ['cookie', 'qr', 'membership'], accountQueries: ['personal-playlists', 'album-collection-status'],
    writes: ['likes', 'playlists', 'collections', 'comments', 'listen'],
    playback: { qualities: ['standard', 'exhigh', 'lossless', 'hires', 'jymaster'], probeEnabled: config.probeAudio,
      sameTrackMatch: 'opt-in-metadata', entitlementBypass: false }, listenDurationSync: 'unverified' }));
  add('get', '/search', '搜索歌曲', req => catalog.search(v.text(req.query.keywords, 'keywords'), page(req), snapshot(req)),
    { parameters: [param('keywords', textSchema(200)), ...paged], result: 'Page' });
  add('get', '/songs', '按输入顺序获取批量歌曲详情', async req => ({ items: await catalog.details(v.ids(req.query.ids), snapshot(req)) }),
    { parameters: [param('ids', { type: 'string', description: '逗号分隔的 1..100 个歌曲 ID' })] });
  add('get', '/songs/:id', '歌曲详情', req => catalog.detail(id(req), snapshot(req)), { result: 'Song' });
  add('get', '/songs/:id/playback', '解析播放地址和试听状态', req => playback.resolve(id(req), quality(req.query.quality),
    v.boolean(req.query.allowMatch, 'allowMatch', false), snapshot(req)), { result: 'Playback', parameters: [
      param('quality', { type: 'string', enum: ['standard', 'exhigh', 'lossless', 'hires', 'jymaster'], default: 'hires' }, false),
      param('allowMatch', { type: 'boolean', default: false }, false)] });
  add('get', '/songs/:id/lyrics', '歌词及时间轴', req => catalog.lyric(id(req), snapshot(req)), { result: 'Lyrics' });
  add('get', '/songs/:id/comments', '歌曲评论分页', req => catalog.comments(id(req), page(req), snapshot(req)), { parameters: paged, result: 'Page' });
  add('get', '/playlists/:id', '歌单元数据', req => catalog.playlist(id(req), snapshot(req)), { result: 'Playlist' });
  add('get', '/playlists/:id/tracks', '歌单曲目分页（保持索引顺序）', req => catalog.tracks(id(req), page(req), snapshot(req)), { parameters: paged, result: 'Page' });
  add('get', '/albums/:id', '专辑详情和歌曲', req => catalog.album(id(req), snapshot(req)));
  add('get', '/artists/:id', '歌手详情和热门歌曲分页', req => catalog.artist(id(req), page(req), snapshot(req)), { parameters: paged, result: 'Page' });
  add('get', '/recommendations/playlists', '推荐歌单', req => catalog.recommendations(v.integer(req.query.limit, 'limit', 20, 1, 100), snapshot(req)),
    { parameters: [paged[0]] });
  add('get', '/recommendations/daily', '已登录账号每日推荐歌曲', async req => { await auth.require(snapshot(req)); return catalog.daily(snapshot(req)); }, { login: true });
  add('get', '/recommendations/personal-playlists', '已登录账号私人推荐歌单', async req => {
    await auth.require(snapshot(req));
    const result = await catalog.personalPlaylists(snapshot(req));
    auth.assertCurrent(snapshot(req));
    return result;
  }, { login: true, result: 'PlaylistList' });
  add('get', '/auth/status', '已验证的账号状态（会员权限未知时不猜测）', req => auth.status(snapshot(req)), { result: 'Account' });
  add('get', '/auth/membership', '查询当前账号 VIP／SVIP 状态与到期时间', req => auth.membership(snapshot(req)), { login: true, result: 'Membership' });
  add('post', '/auth/cookie', '验证并保存 Cookie', req => auth.importCookie(b(req).cookie),
    { body: body({ cookie: { oneOf: [{ type: 'string' }, { type: 'object' }, { type: 'array', items: { type: 'object' } }] } }), result: 'Account' });
  add('post', '/auth/logout', '删除本服务的登录凭据', () => auth.logout());
  add('post', '/auth/qr', '创建扫码登录会话', () => auth.createQr());
  add('get', '/auth/qr/:sessionId', '轮询二维码状态（至少间隔 2 秒）', req => {
    if (!UUID.test(req.params.sessionId)) v.invalid('sessionId 必须为 UUID');
    return auth.pollQr(req.params.sessionId);
  });
  add('get', '/me/playlists', '我的歌单分页', req => library.playlists(page(req), snapshot(req)), { parameters: paged, login: true, result: 'Page' });
  add('get', '/me/likes', '我喜欢的歌曲 ID', req => library.likes(snapshot(req)), { login: true });
  add('get', '/me/collections/albums/status', '批量查询专辑收藏状态（未扫描到的项可能为未知）', req =>
    library.albumCollectionStatus(v.ids(v.text(req.query.ids, 'ids', 2100)), v.integer(req.query.maxPages, 'maxPages', 8, 1, 20), snapshot(req)),
    { login: true, result: 'AlbumCollectionStatus', parameters: [param('ids', { type: 'string', description: '逗号分隔的 1..100 个专辑 ID' }),
      param('maxPages', { type: 'integer', minimum: 1, maximum: 20, default: 8 }, false)] });
  add('put', '/me/likes/:id', '喜欢或取消喜欢歌曲', req => library.like(id(req), v.boolean(b(req).liked, 'liked'), snapshot(req)),
    { body: body({ liked: boolSchema }), login: true });
  add('post', '/playlists', '创建歌单', req => library.createPlaylist(v.text(b(req).name, 'name', 40), v.boolean(b(req).private, 'private', false), snapshot(req)),
    { body: body({ name: textSchema(40), private: boolSchema }, ['name']), login: true, result: 'Playlist' });
  add('post', '/playlists/:id/tracks', '向歌单添加歌曲', req => library.tracks(id(req), v.ids(b(req).ids), 'add', snapshot(req)),
    { body: body({ ids: idsSchema }), login: true });
  add('delete', '/playlists/:id/tracks', '从歌单移除歌曲', req => library.tracks(id(req), v.ids(b(req).ids), 'del', snapshot(req)),
    { body: body({ ids: idsSchema }), login: true });
  for (const [resource, kind] of [['playlists', 'playlist'], ['albums', 'album']]) {
    add('put', `/me/collections/${resource}/:id`, '收藏或取消收藏', req => library.collect(kind, id(req), v.boolean(b(req).collected, 'collected'), snapshot(req)),
      { body: body({ collected: boolSchema }), login: true });
  }
  add('post', '/songs/:id/comments', '发表歌曲评论', req => library.comment(id(req), v.text(b(req).content, 'content', 500), snapshot(req)),
    { body: body({ content: textSchema(500) }), login: true });
  add('put', '/songs/:id/comments/:commentId/like', '点赞或取消点赞评论', req => library.likeComment(id(req), v.identifier(req.params.commentId, 'commentId'),
    v.boolean(b(req).liked, 'liked'), snapshot(req)), { body: body({ liked: boolSchema }), login: true });
  add('post', '/listen', '上报真实听歌记录（不保证账户时长累计）', req => library.listen(v.identifier(b(req).id),
    b(req).sourceId === undefined || b(req).sourceId === '0' ? '0' : v.identifier(b(req).sourceId, 'sourceId'), v.integer(b(req).seconds, 'seconds', undefined, 1, 86400), snapshot(req)),
    { body: body({ id: idSchema, sourceId: { type: 'string', pattern: '^(0|[1-9][0-9]*)$' }, seconds: { type: 'integer', minimum: 1, maximum: 86400 } }, ['id', 'seconds']), login: true });
  add('get', '/podcasts/search', '搜索播客', req => catalog.podcastSearch(v.text(req.query.keywords, 'keywords'), page(req), snapshot(req)),
    { parameters: [param('keywords', textSchema(200)), ...paged], result: 'Page' });
  add('get', '/podcasts/hot', '热门播客分页', req => catalog.podcastHot(page(req), snapshot(req)), { parameters: paged, result: 'Page' });
  add('get', '/podcasts/:id', '播客详情', req => catalog.podcast(id(req), snapshot(req)));
  add('get', '/podcasts/:id/programs', '播客节目分页（mainSong.id 用于播放）', req => catalog.programs(id(req), page(req), snapshot(req)), { parameters: paged, result: 'Page' });
  add('post', '/media/tickets', '签发网易云 CDN 封面或音频票据', req => {
    const input = b(req); const kind = input.kind || 'cover';
    if (!['audio', 'cover'].includes(kind)) v.invalid('kind 必须为 audio 或 cover');
    return { proxyUrl: media.path(v.text(input.url, 'url', 8000), kind), expiresInSeconds: config.mediaTtlSeconds };
  }, { body: body({ url: textSchema(8000), kind: { type: 'string', enum: ['audio', 'cover'], default: 'cover' } }, ['url']) });
  for (const kind of ['audio', 'cover']) {
    for (const method of ['get', 'head']) add(method, `/media/${kind}`, '使用媒体票据代理（支持单 Range）', (req, res) => media.proxy(req, res, kind),
      { binary: true, public: true, parameters: [param('ticket', { type: 'string' }),
        { name: 'Range', in: 'header', required: false, schema: { type: 'string', example: 'bytes=0-8191' } }] });
  }
  return routes;
}

function installRoutes(app, routes, store) {
  // Capture the credential once per request, never read a changing global mid-operation.
  app.use((req, _res, next) => { req.accountSnapshot = store.snapshot(); next(); });
  for (const route of routes) {
    app[route.method](`/api/v1${route.path}`, async (req, res) => {
      const data = await route.handler(req, res);
      if (!route.binary) res.json({ success: true, data, requestId: req.requestId });
    });
  }
  const byPath = new Map();
  for (const route of routes) {
    const path = `/api/v1${route.path}`;
    const methods = byPath.get(path) || new Set();
    methods.add(route.method.toUpperCase());
    if (route.method === 'get') methods.add('HEAD');
    byPath.set(path, methods);
  }
  for (const [path, methods] of byPath) app.all(path, (req, res, next) => {
    res.set('Allow', [...methods, 'OPTIONS'].join(', '));
    next(new AppError('METHOD_NOT_ALLOWED', '此接口不支持该 HTTP 方法', 405));
  });
}

module.exports = { defineRoutes, installRoutes };
