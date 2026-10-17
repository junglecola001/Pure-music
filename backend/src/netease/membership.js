'use strict';

// Only explicit membership packages from the VIP endpoints are evidence.
// Profile badges, vipType and arbitrary strings do not establish entitlement.
function packageState(pkg, now) {
  if (pkg === null) return { active: false, expiresAt: null };
  if (!pkg || typeof pkg !== 'object' || Array.isArray(pkg)) return { active: null, expiresAt: null };
  const raw = pkg.expireTime ?? pkg.expire_time ?? pkg.endTime;
  const expiry = Number(raw);
  const valid = ['number', 'string'].includes(typeof raw) && /^\d+$/.test(String(raw)) && Number.isSafeInteger(expiry);
  if (!valid) return { active: null, expiresAt: null };
  // The upstream contract uses Unix milliseconds. Do not guess missing dates.
  return { active: expiry > now, expiresAt: expiry > 0 ? expiry : null };
}

function normalizeMembership(body, now = Date.now()) {
  const data = body?.data || body;
  if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
  if (data.code !== undefined && Number(data.code) !== 200) return null;
  const has = key => Object.prototype.hasOwnProperty.call(data, key);
  const states = {
    svip: packageState(has('redplus') ? data.redplus : data.redPlus, now),
    vip: packageState(data.associator, now),
    music: packageState(has('musicPackage') ? data.musicPackage : data.music_package, now),
  };
  const active = Object.values(states).filter(s => s.active === true);
  let membership = 'unknown';
  if (states.svip.active === true) membership = 'svip';
  else if (states.vip.active === true || states.music.active === true) membership = 'vip';
  else if (Object.values(states).every(s => s.active === false)) membership = 'none';
  if (membership === 'unknown') return null;
  return { membership, isVip: membership !== 'none',
    isSvip: states.svip.active === true ? true : states.svip.active === false ? false : null,
    expiresAt: membership === 'svip' ? states.svip.expiresAt :
      active.length ? Math.max(...active.map(s => s.expiresAt)) : null,
    // Refresh at any package expiry, including an SVIP -> VIP transition.
    refreshAt: active.length ? Math.min(...active.map(s => s.expiresAt)) : null };
}

module.exports = { normalizeMembership };
