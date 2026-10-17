'use strict';

class TTLCache {
  constructor(max = 300, now = Date.now) {
    this.max = max;
    this.now = now;
    this.entries = new Map();
  }
  get(key) {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expires <= this.now()) {
      this.entries.delete(key);
      return undefined;
    }
    this.entries.delete(key);
    this.entries.set(key, entry);
    return entry.value;
  }
  set(key, value, ttlMs) {
    this.entries.delete(key);
    this.entries.set(key, { value, expires: this.now() + ttlMs });
    while (this.entries.size > this.max) this.entries.delete(this.entries.keys().next().value);
    return value;
  }
  clear() { this.entries.clear(); }
}

module.exports = { TTLCache };
