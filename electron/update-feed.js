'use strict';

// GitHub release feed for Electron's built-in autoUpdater.
// update.electronjs.org reads the public GitHub Release assets directly; the
// release workflow keeps uploading EasyLens-<version>-mac-<arch>.zip, which
// matches its "-mac" + "-x64"/"-arm64" asset naming heuristics.
const GITHUB_OWNER = 'allen-bot-ctl';
const GITHUB_REPO = 'EasyLens';
const UPDATE_SERVER = 'https://update.electronjs.org';
const RELEASES_LATEST_URL =
  `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest`;
const HOMEPAGE_URL = 'https://allen-bot-ctl.github.io/EasyLens/';
// Windows / Linux 只检查不自更新：update.electronjs.org 不服务 Linux，
// Windows 的 NSIS 包也不是 Squirrel.Windows 格式。这里跟随 github.com 的
// /releases/latest 跳转读出最新 tag（不走 api.github.com，避免匿名 60 次/小时的限流）。
const LATEST_RELEASE_PAGE = RELEASES_LATEST_URL;

function requireText(value, name) {
  if (typeof value !== 'string' || value.trim() === '') {
    throw new TypeError(`${name} is required`);
  }
  return value.trim();
}

function buildFeedUrl(options = {}) {
  const owner = requireText(options.owner ?? GITHUB_OWNER, 'owner');
  const repo = requireText(options.repo ?? GITHUB_REPO, 'repo');
  const platform = requireText(options.platform, 'platform');
  const arch = requireText(options.arch, 'arch');
  const version = requireText(options.version, 'version');
  const server = requireText(options.server ?? UPDATE_SERVER, 'server')
    .replace(/\/+$/, '');

  return `${server}/${owner}/${repo}/${platform}-${arch}/${version}`;
}

// Interprets a probe of the update feed without doing any network I/O.
// 204 means "no update" (up-to-date). 200 with a valid update payload means a
// newer release exists but this unsigned build cannot apply it automatically, so
// the caller should offer a manual download. Any other status or an invalid
// payload is treated as a real check failure.
function interpretFeedProbe(status, payload) {
  if (status === 204) return { state: 'up-to-date' };

  if (status === 200) {
    const name = payload && typeof payload.name === 'string'
      ? payload.name.trim()
      : '';
    const url = payload && typeof payload.url === 'string'
      ? payload.url.trim()
      : '';
    if (name || url) {
      const result = { state: 'manual', name: name || 'latest' };
      if (url) result.url = url;
      return result;
    }
  }

  return { state: 'error' };
}

// Interprets where https://github.com/<owner>/<repo>/releases/latest landed
// for the check-only platforms. Returns { state: 'available', version, name,
// url } when the tag is newer than currentVersion, 'up-to-date' when not, and
// 'error' for anything unexpected.
function interpretLatestRelease(status, finalUrl, currentVersion) {
  if (status !== 200 || typeof finalUrl !== 'string') return { state: 'error' };
  const prefix = `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/`;
  if (!finalUrl.startsWith(prefix)) return { state: 'error' };
  let tag = finalUrl.slice(prefix.length).split(/[?#/]/)[0];
  try {
    tag = decodeURIComponent(tag);
  } catch {
    return { state: 'error' };
  }
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(tag);
  const current = /^(\d+)\.(\d+)\.(\d+)$/.exec(String(currentVersion || '').trim());
  if (!match || !current) return { state: 'error' };
  let newer = false;
  for (let i = 1; i <= 3; i += 1) {
    const a = Number(match[i]);
    const b = Number(current[i]);
    if (a !== b) {
      newer = a > b;
      break;
    }
  }
  if (!newer) return { state: 'up-to-date' };
  const version = `${match[1]}.${match[2]}.${match[3]}`;
  return {
    state: 'available',
    version,
    name: `EasyLens v${version}`,
    url: `${prefix}v${version}`
  };
}

module.exports = {
  GITHUB_OWNER,
  GITHUB_REPO,
  UPDATE_SERVER,
  RELEASES_LATEST_URL,
  HOMEPAGE_URL,
  LATEST_RELEASE_PAGE,
  buildFeedUrl,
  interpretFeedProbe,
  interpretLatestRelease
};
