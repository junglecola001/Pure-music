'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { defineRoutes } = require('../src/http/routes');
const { openapi } = require('../src/http/openapi');
const specification = openapi(defineRoutes({}));
fs.writeFileSync(path.join(__dirname, '../docs/openapi.json'), JSON.stringify(specification, null, 2) + '\n');
console.log(`OpenAPI generated: ${Object.keys(specification.paths).length} paths`);
