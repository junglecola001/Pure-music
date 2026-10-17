'use strict';

const express = require('express');
const { loadConfig } = require('./config');
const { CredentialStore } = require('./core/credentials');
const { Media } = require('./core/media');
const { AppError } = require('./core/errors');
const { NeteaseClient } = require('./netease/client');
const { Catalog } = require('./netease/catalog');
const { Auth } = require('./netease/auth');
const { Library } = require('./netease/library');
const { Playback } = require('./netease/playback');
const { middleware, errorHandler } = require('./http/middleware');
const { defineRoutes, installRoutes } = require('./http/routes');
const { legacyAliases } = require('./http/legacy');
const { openapi } = require('./http/openapi');

function createApp(options = {}) {
  const config = options.config || loadConfig();
  const store = options.store || new CredentialStore(config);
  const client = options.client || new NeteaseClient(options.api || require('./netease/sdk').loadSdk(config.upstreamTimeoutMs), config.upstreamTimeoutMs);
  const media = options.media || new Media(config);
  const catalog = new Catalog(client);
  const playback = new Playback(client, catalog, media, config);
  const auth = new Auth(client, store, () => { catalog.clear(); playback.clear(); });
  const library = new Library(client, auth, catalog);
  const services = { config, store, client, media, catalog, playback, auth, library };
  const app = express();
  app.disable('x-powered-by');
  app.set('query parser', 'simple');
  app.use(middleware(config));
  app.use((req, _res, next) => {
    if (['POST', 'PUT', 'DELETE'].includes(req.method) && (Number(req.headers['content-length'] || 0) > 0 || req.headers['transfer-encoding']) && !req.is('application/json')) {
      return next(new AppError('UNSUPPORTED_MEDIA_TYPE', '请求体必须使用 application/json', 415));
    }
    next();
  });
  app.use(express.json({ limit: '64kb' }));
  app.use(legacyAliases);
  const routes = defineRoutes(services);
  const specification = openapi(routes);
  app.get('/api/v1/openapi.json', (_req, res) => res.json(specification));
  app.all('/api/v1/openapi.json', (_req, res, next) => { res.set('Allow', 'GET, HEAD, OPTIONS'); next(new AppError('METHOD_NOT_ALLOWED', '此接口只支持 GET', 405)); });
  installRoutes(app, routes, store);
  app.use((_req, _res, next) => next(new AppError('NOT_FOUND', '接口不存在', 404)));
  app.use(errorHandler);
  app.locals.services = services;
  app.locals.openapi = specification;
  return app;
}

module.exports = { createApp };
