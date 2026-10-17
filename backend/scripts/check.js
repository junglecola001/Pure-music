'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
let count = 0;
function check(directory) {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const file = path.join(directory, entry.name);
    if (entry.isDirectory()) check(file);
    else if (file.endsWith('.js') || file.endsWith('.mjs')) { execFileSync(process.execPath, ['--check', file], { stdio: 'inherit' }); count++; }
  }
}
for (const directory of ['src', 'scripts', 'test', 'examples']) check(directory);
execFileSync(process.execPath, ['--check', 'server.js'], { stdio: 'inherit' });
console.log(`Syntax OK: ${count + 1} JavaScript files`);
