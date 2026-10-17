// Read-only upstream checks; media ticket signing does not mutate the music account.
// Run with: npm run verify:live  (MUSIC_VERIFY_ORIGIN / MUSIC_VERIFY_TOKEN override the target).
const origin = process.env.MUSIC_VERIFY_ORIGIN || 'http://127.0.0.1:3000';
const token = process.env.MUSIC_VERIFY_TOKEN || '';
const results = [];
async function request(name, path, options = {}) {
  try {
    const response = await fetch(`${origin}/api/v1${path}`, { ...options, signal: AbortSignal.timeout(20_000), headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(options.body ? { 'Content-Type': 'application/json' } : {}),
    } });
    const payload = await response.json();
    results.push({ name, http: response.status, success: payload.success, ...(payload.error ? { code: payload.error.code } : {}) });
    if (!response.ok || !payload.success) {
      if (payload.error?.details?.reason) results.at(-1).reason = payload.error.details.reason;
      return undefined;
    }
    return payload.data;
  } catch (error) { results.push({ name, success: false, error: error.name }); return undefined; }
}
await request('health', '/health');
const recommendations = await request('recommendations', '/recommendations/playlists?limit=6');
if (recommendations) results.at(-1).count = recommendations.items.length;
const search = await request('search', `/search?keywords=${encodeURIComponent('钢琴')}&limit=3`);
if (search) results.at(-1).count = search.items.length;
await request('lyrics', '/songs/186016/lyrics');
const playback = await request('free-song-playback', '/songs/2007983648/playback?quality=exhigh&allowMatch=false');
if (playback) {
  Object.assign(results.at(-1), { playbackStatus: playback.status, playable: playback.playable, quality: playback.quality, verified: playback.verified });
  if (playback.playable && playback.proxyUrl) {
    try { const response = await fetch(new URL(playback.proxyUrl, origin), { headers: { Range: 'bytes=0-1023' }, signal: AbortSignal.timeout(20_000) });
      results.push({ name: 'audio-range', http: response.status, range: response.headers.get('Content-Range'), success: response.status === 206 }); await response.body?.cancel();
    } catch (error) { results.push({ name: 'audio-range', success: false, error: error.name }); }
  }
}
const cover = search?.items[0]?.cover;
if (cover) {
  const ticket = await request('cover-ticket', '/media/tickets', { method: 'POST', body: JSON.stringify({ url: cover, kind: 'cover' }) });
  if (ticket) {
    try { const response = await fetch(new URL(ticket.proxyUrl, origin), { method: 'HEAD', signal: AbortSignal.timeout(20_000) });
      results.push({ name: 'cover-head', http: response.status, type: response.headers.get('Content-Type'), success: response.ok });
      if (!response.ok) {
        const detail = await fetch(new URL(ticket.proxyUrl, origin), { signal: AbortSignal.timeout(20_000) });
        const error = await detail.json().catch(() => undefined);
        if (error?.error?.code) results.at(-1).code = error.error.code;
      }
    } catch (error) { results.push({ name: 'cover-head', success: false, error: error.name }); }
  }
}
console.log(JSON.stringify({ origin, checks: results }, null, 2));
if (results.some(r => !r.success)) process.exitCode = 1;
