'use strict';

// 0.1.9：把更新器状态翻成托盘菜单和系统通知（契约 docs/changes/0.1.9-in-app-update.md
// 的状态表，同一时刻只出现一种）。纯函数，便于单测。
//
// status: { state, manual, name, url }
//   state ∈ idle | checking | up-to-date | downloading | ready | manual |
//           checksum | arch | error | available | disabled
// 返回：
//   entry        托盘里「检查更新…」那一行 { label, enabled, action, url? }
//   top          菜单顶部额外一行（只有已就绪时才有）{ label, action }
//   notification 系统通知文字；null 表示不出声
//   openUrl      手动触发时需要顺手打开的下载页（契约里「已为你打开下载页」）

const { extractVersion } = require('./mac-self-update');

const CHECK_LABEL = '检查更新…';

function versionOf(status) {
  return extractVersion(status && status.name) ||
    extractVersion(status && status.url) ||
    (status && typeof status.version === 'string' ? status.version : '');
}

function describeTray(status, options = {}) {
  const state = status && typeof status.state === 'string' ? status.state : 'idle';
  const manual = Boolean(status && status.manual === true);
  const current = options.currentVersion || '';
  const next = versionOf(status);
  const url = status && typeof status.url === 'string' ? status.url : null;
  const check = { label: CHECK_LABEL, enabled: true, action: 'check' };
  const download = { label: next ? `下载新版本 ${next}…` : '下载新版本…', enabled: true, action: 'open', url };

  switch (state) {
    case 'checking':
      return { state, entry: { label: '正在检查…', enabled: false, action: null }, top: null, notification: null, openUrl: null };
    case 'up-to-date':
      return {
        state,
        entry: check,
        top: null,
        notification: manual ? `已是最新版本 ${current}` : null,
        openUrl: null
      };
    case 'downloading':
      return {
        state,
        entry: { label: `正在下载 ${next}…`, enabled: false, action: null },
        top: null,
        notification: manual ? `发现新版本 ${next}，正在下载` : null,
        openUrl: null
      };
    case 'ready':
      return {
        state,
        entry: check,
        top: { label: `重启以更新到 ${next}`, action: 'install' },
        // 只提示一次：main.js 按版本记住已经提示过。
        notification: '新版本已就绪，在托盘里点重启即可更新',
        notifyOnce: `ready:${next}`,
        openUrl: null
      };
    case 'manual':
      return {
        state,
        entry: download,
        top: null,
        notification: manual ? '无法自动更新，已为你打开下载页' : null,
        openUrl: manual ? url : null
      };
    case 'checksum':
      return {
        state,
        entry: download,
        top: null,
        notification: manual ? '更新包校验失败，已为你打开下载页' : null,
        openUrl: manual ? url : null
      };
    case 'arch':
      return {
        state,
        entry: download,
        top: null,
        notification: manual ? '无法自动更新，已为你打开下载页' : null,
        openUrl: manual ? url : null
      };
    case 'available':
      return {
        state,
        entry: download,
        top: null,
        notification: manual ? `发现新版本 ${next}，点托盘里的「下载新版本」即可下载` : null,
        openUrl: null
      };
    case 'error':
      return {
        state,
        entry: check,
        top: null,
        notification: manual ? '检查更新失败，请稍后再试' : null,
        openUrl: null
      };
    case 'disabled':
      return {
        state,
        entry: check,
        top: null,
        notification: manual ? '开发版不检查更新' : null,
        openUrl: null
      };
    default:
      return { state: 'idle', entry: check, top: null, notification: null, openUrl: null };
  }
}

// 已就绪的包还在磁盘上：自动检查偶尔失败或回报「没有新版」时，不把托盘上的
// 「重启以更新」冲掉。手动检查和其他状态照常替换。
function shouldKeepPrevious(previous, next) {
  if (!previous || previous.state !== 'ready' || !next) return false;
  if (next.manual === true) return false;
  return next.state === 'error' || next.state === 'up-to-date';
}

module.exports = {
  CHECK_LABEL,
  describeTray,
  shouldKeepPrevious
};
