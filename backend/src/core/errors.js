'use strict';

class AppError extends Error {
  constructor(code, message, status = 500, details) {
    super(message);
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

function upstreamError(error) {
  if (error instanceof AppError) return error;
  const code = Number(error?.body?.code || error?.status || error?.statusCode);
  if ([301, 401, 403].includes(code)) {
    return new AppError('LOGIN_REQUIRED', '网易云登录失效或没有操作权限', 401);
  }
  return new AppError('UPSTREAM_ERROR', '网易云接口请求失败', 502);
}

module.exports = { AppError, upstreamError };
