'use strict';

const ref = name => ({ $ref: `#/components/schemas/${name}` });
const string = { type: 'string' };
const nullableString = { type: ['string', 'null'] };
const properties = props => ({ type: 'object', properties: props });
const schemas = {
  Error: { type: 'object', required: ['success', 'error', 'requestId'], properties: {
    success: { const: false }, error: properties({ code: string, message: string, details: { type: 'object' } }), requestId: string } },
  Song: properties({ provider: { const: 'netease' }, id: string, name: string, artist: string,
    artists: { type: 'array', items: properties({ id: string, name: string }) },
    album: properties({ id: string, name: string, cover: string }), cover: string,
    durationMs: { type: 'number' }, fee: { type: 'number' }, popularity: { type: 'number' } }),
  Playlist: properties({ provider: { const: 'netease' }, id: string, name: string, cover: string,
    description: string, trackCount: { type: 'number' }, playCount: { type: 'number' },
    creator: properties({ id: string, name: string }), subscribed: { type: 'boolean' } }),
  Page: properties({ items: { type: 'array', items: { type: 'object' } }, total: { type: ['integer', 'null'] },
    limit: { type: 'integer' }, offset: { type: 'integer' }, nextOffset: { type: 'integer' }, hasMore: { type: 'boolean' } }),
  Playback: properties({ id: string, requestedId: string, resolvedId: string,
    status: { enum: ['full', 'trial', 'unavailable'] }, playable: { type: 'boolean' }, trial: { type: 'boolean' },
    url: nullableString, proxyUrl: nullableString, requestedQuality: string, quality: nullableString,
    bitrate: { type: ['number', 'null'] }, format: nullableString, size: { type: ['number', 'null'] },
    expiresAt: { type: 'number' }, verified: { type: 'boolean' }, matched: { type: 'boolean' },
    restriction: { type: ['object', 'null'], properties: { code: string, message: string, action: string } },
    trialInfo: { type: ['object', 'null'] }, matchedSong: ref('Song'), matchBasis: string,
    originalRestriction: { type: ['object', 'null'] } }),
  Lyrics: properties({ id: string, original: string, translated: string, romanized: string, wordByWord: string,
    lines: { type: 'array', items: properties({ timeMs: { type: 'number' }, text: string }) }, instrumental: { type: 'boolean' } }),
  Membership: properties({ membership: { enum: ['vip', 'svip', 'none', 'unknown'] },
    isVip: { type: ['boolean', 'null'] }, isSvip: { type: ['boolean', 'null'] },
    expiresAt: { type: ['number', 'null'] }, checkedAt: { type: 'number' },
    source: { enum: ['vip_info_v2', 'vip_info', null] }, errorCode: string }),
  Account: { allOf: [ref('Membership'), properties({ loggedIn: { type: 'boolean' }, hasCookie: { type: 'boolean' }, userId: nullableString,
    nickname: string, avatar: string })] },
  PlaylistList: properties({ items: { type: 'array', items: ref('Playlist') } }),
  AlbumCollectionStatus: properties({ ids: { type: 'array', items: string },
    collected: { type: 'object', additionalProperties: { type: ['boolean', 'null'] } },
    complete: { type: 'boolean' }, scanned: { type: 'integer' }, nextOffset: { type: ['integer', 'null'] } }),
};
function openapi(routes) {
  const paths = {};
  for (const route of routes) {
    const path = `/api/v1${route.path.replace(/:(\w+)/g, '{$1}')}`;
    const parameters = [...route.path.matchAll(/:(\w+)/g)].map(match => ({ name: match[1], in: 'path', required: true,
      schema: match[1] === 'sessionId' ? { type: 'string', format: 'uuid' } : { type: 'string', pattern: '^[1-9][0-9]*$' } }));
    parameters.push(...(route.parameters || []));
    const response = route.binary ? { description: '媒体数据', content: { 'application/octet-stream': { schema: { type: 'string', format: 'binary' } } } }
      : { description: '成功', content: { 'application/json': { schema: { type: 'object', required: ['success', 'data', 'requestId'],
        properties: { success: { const: true }, data: route.result ? ref(route.result) : { type: 'object' }, requestId: string } } } } };
    paths[path] ||= {};
    paths[path][route.method] = {
      operationId: `${route.method}_${route.path.replace(/\W+/g, '_')}`, summary: route.summary,
      description: route.login ? '需要本服务保存的有效网易云账号登录状态。' : undefined,
      security: route.public ? [] : [{ bearerAuth: [] }], parameters,
      ...(route.body ? { requestBody: { required: true, content: { 'application/json': { schema: route.body } } } } : {}),
      responses: { 200: response, ...(route.binary ? { 206: response, 416: { description: 'Range 无效或越界' } } : {}),
        default: { description: '错误；具体 HTTP 状态和 error.code 见 API.md', content: { 'application/json': { schema: ref('Error') } } } },
    };
  }
  paths['/api/v1/openapi.json'] = { get: { summary: '本接口文档', security: [{ bearerAuth: [] }], responses: { 200: { description: 'OpenAPI 3.1 JSON' } } } };
  return { openapi: '3.1.0', info: { title: '网易云音乐音源 API 后端', version: '1.0.0',
    description: '自用／单账号网易云音乐 API 服务，不包含前端页面。Bearer 鉴权仅在配置 API_TOKEN 后启用。健康检查和持票据媒体请求无需 Bearer。第三方权限由网易云决定。' },
    servers: [{ url: '/' }], paths, components: { schemas, securitySchemes: { bearerAuth: { type: 'http', scheme: 'bearer' } } } };
}

module.exports = { openapi };
