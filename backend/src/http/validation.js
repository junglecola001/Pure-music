'use strict';

const { AppError } = require('../core/errors');
const invalid = message => { throw new AppError('INVALID_ARGUMENT', message, 400); };
function text(value, name, max = 200) {
  if (typeof value !== 'string' || !value.trim() || value.trim().length > max) invalid(`${name} 必须为 1..${max} 字符的字符串`);
  return value.trim();
}
function identifier(value, name = 'id') {
  const result = text(value, name, 20);
  if (!/^[1-9]\d*$/.test(result) || !Number.isSafeInteger(Number(result))) invalid(`${name} 必须为正整数字符串`);
  return result;
}
function ids(value) {
  const values = typeof value === 'string' ? value.split(',') : value;
  if (!Array.isArray(values) || !values.length || values.length > 100) invalid('ids 必须包含 1..100 个资源 ID');
  return [...new Set(values.map(v => identifier(typeof v === 'number' ? String(v) : v)))];
}
function integer(value, name, fallback, min = 0, max = 1000000) {
  if (value === undefined) {
    if (fallback === undefined) invalid(`${name} 为必填参数`);
    return fallback;
  }
  if (!['string', 'number'].includes(typeof value) || !/^\d+$/.test(String(value))) invalid(`${name} 必须为整数`);
  const n = Number(value);
  if (!Number.isSafeInteger(n) || n < min || n > max) invalid(`${name} 必须在 ${min}..${max} 之间`);
  return n;
}
function boolean(value, name, fallback) {
  if (value === undefined && fallback !== undefined) return fallback;
  if (value === true || value === 'true') return true;
  if (value === false || value === 'false') return false;
  invalid(`${name} 必须为 true 或 false`);
}
function pagination(query) {
  return { limit: integer(query.limit, 'limit', 20, 1, 100), offset: integer(query.offset, 'offset', 0) };
}
function bodyObject(body) {
  if (!body || Array.isArray(body) || typeof body !== 'object') invalid('请求体必须为 JSON 对象');
  return body;
}

module.exports = { text, identifier, ids, integer, boolean, pagination, bodyObject, invalid };
