'use strict';

const http = require('node:http');
const { createApp } = require('./src/app');
const { loadConfig } = require('./src/config');

function start() {
  const config = loadConfig();
  const server = http.createServer(createApp({ config }));
  server.requestTimeout = 30000;
  server.headersTimeout = 15000;
  server.keepAliveTimeout = 5000;
  server.listen(config.port, config.host, () => {
    console.log(`NetEase player backend: http://${config.host}:${server.address().port}/api/v1`);
    console.log(`Account: single | API auth: ${config.apiToken ? 'enabled' : 'disabled (loopback only)'}`);
  });
  let stopping = false;
  const shutdown = () => {
    if (stopping) return;
    stopping = true;
    server.close(() => process.exit(0));
    setTimeout(() => { server.closeAllConnections(); process.exit(0); }, 10000).unref();
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
  server.once('error', err => { console.error(`Server failed: ${err.code || err.message}`); process.exitCode = 1; });
  return server;
}

if (require.main === module) start();
module.exports = { start, createApp };
