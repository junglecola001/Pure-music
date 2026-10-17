'use strict';

const { AppError } = require('./errors');
const QUALITIES = [
  { level: 'jymaster', bitrate: 1999000 }, { level: 'hires', bitrate: 1999000 },
  { level: 'lossless', bitrate: 1411000 }, { level: 'exhigh', bitrate: 320000 },
  { level: 'standard', bitrate: 128000 },
];
const ALIASES = { master: 'jymaster', 'hi-res': 'hires', flac: 'lossless', sq: 'lossless',
  high: 'exhigh', '320': 'exhigh', normal: 'standard', '128': 'standard' };
function quality(value = 'hires') {
  if (typeof value !== 'string') throw new AppError('INVALID_ARGUMENT', 'quality 必须为字符串', 400);
  const level = ALIASES[value.toLowerCase()] || value.toLowerCase();
  if (!QUALITIES.some(q => q.level === level)) throw new AppError('INVALID_ARGUMENT', '未知音质', 400);
  return level;
}
function candidates(level) { return QUALITIES.slice(QUALITIES.findIndex(q => q.level === quality(level))); }
function actualLevel(data, legacy = false) {
  if (!legacy && QUALITIES.some(q => q.level === data.level)) return data.level;
  if (/flac/i.test(data.type || '')) return 'lossless';
  if (Number(data.br) >= 256000) return 'exhigh';
  if (Number(data.br) > 0) return 'standard';
  return 'unknown';
}
function magic(buffer) {
  if (buffer.length >= 3 && buffer.subarray(0, 3).toString() === 'ID3') return 'mp3';
  if (buffer.length >= 4 && buffer.subarray(0, 4).toString() === 'fLaC') return 'flac';
  if (buffer.length >= 4 && buffer.subarray(0, 4).toString() === 'OggS') return 'ogg';
  if (buffer.length >= 12 && buffer.subarray(0, 4).toString() === 'RIFF' && buffer.subarray(8, 12).toString() === 'WAVE') return 'wav';
  if (buffer.length >= 12 && buffer.subarray(4, 8).toString() === 'ftyp') return 'mp4';
  // Require a valid MPEG version, layer, bitrate and sample rate, not merely 0xff.
  for (let i = 0; i + 3 < Math.min(buffer.length, 2048); i++) {
    const b = buffer[i + 1]; const c = buffer[i + 2];
    if (buffer[i] === 255 && (b & 224) === 224 && (b & 24) !== 8 && (b & 6) !== 0 &&
      (c & 240) !== 0 && (c & 240) !== 240 && (c & 12) !== 12) return 'mp3';
  }
  return null;
}

module.exports = { QUALITIES, quality, candidates, actualLevel, magic };
