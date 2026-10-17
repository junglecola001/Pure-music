'use strict';

// Load only the protocol modules we use, not the SDK's server or upload endpoints.
const METHODS = [
  'cloudsearch', 'song_detail', 'song_url_v1', 'song_url', 'lyric', 'lyric_new',
  'comment_music', 'playlist_detail', 'album', 'artist_detail', 'artist_songs',
  'artist_top_song', 'login_status', 'login_qr_key', 'login_qr_create', 'login_qr_check',
  'user_playlist', 'likelist', 'like', 'playlist_create', 'playlist_tracks',
  'playlist_subscribe', 'album_sub', 'comment', 'comment_like', 'scrobble',
  'personalized', 'recommend_songs', 'dj_hot', 'dj_detail', 'dj_program',
  'vip_info_v2', 'vip_info', 'recommend_resource', 'album_sublist',
];

function loadSdk(timeoutMs = 8000) {
  const request = require('./transport').createTransport(timeoutMs);
  const { cookieToJson } = require('NeteaseCloudMusicApi/util');
  return Object.fromEntries(METHODS.map(method => {
    const fn = require(`NeteaseCloudMusicApi/module/${method}`);
    return [method, params => fn({ ...params, cookie: cookieToJson(params.cookie || '') }, request)];
  }));
}

module.exports = { loadSdk, METHODS };
