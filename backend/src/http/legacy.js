'use strict';

const { AppError } = require('../core/errors');

const ALIASES = {
  '/api/search': { method: 'GET', path: () => '/search' },
  '/api/song/detail': { method: 'GET', path: q => `/songs/${encodeURIComponent(q.id || '')}` },
  '/api/song/url': { method: 'GET', path: q => `/songs/${encodeURIComponent(q.id || '')}/playback` },
  '/api/lyric': { method: 'GET', path: q => `/songs/${encodeURIComponent(q.id || '')}/lyrics` },
  '/api/song/comments': { method: 'GET', path: q => `/songs/${encodeURIComponent(q.id || '')}/comments` },
  '/api/playlist/tracks': { method: 'GET', path: q => `/playlists/${encodeURIComponent(q.id || '')}/tracks` },
  '/api/album/detail': { method: 'GET', path: q => `/albums/${encodeURIComponent(q.id || '')}` },
  '/api/artist/detail': { method: 'GET', path: q => `/artists/${encodeURIComponent(q.id || '')}` },
  '/api/login/status': { method: 'GET', path: () => '/auth/status' },
  '/api/login/cookie': { method: 'POST', path: () => '/auth/cookie' },
  '/api/logout': { method: 'POST', path: () => '/auth/logout' },
  '/api/user/playlists': { method: 'GET', path: () => '/me/playlists' },
};
function legacyAliases(req, res, next) {
  const alias = ALIASES[req.path];
  if (!alias) return next();
  res.set('Deprecation', 'true');
  if (req.method !== alias.method && !(req.method === 'HEAD' && alias.method === 'GET')) {
    res.set('Allow', alias.method);
    return next(new AppError('METHOD_NOT_ALLOWED', '兼容接口不支持该 HTTP 方法', 405));
  }
  const query = new URLSearchParams(req.url.split('?')[1] || '');
  req.url = `/api/v1${alias.path(req.query)}?${query}`;
  next();
}

module.exports = { ALIASES, legacyAliases };
