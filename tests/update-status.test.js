'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const { describeTray, shouldKeepPrevious, CHECK_LABEL } = require('../electron/update-status');
const { setupAutoUpdate } = require('../electron/updater');
const { buildFeedUrl, interpretLatestRelease, LATEST_RELEASE_PAGE } = require('../electron/update-feed');

const CUR = { currentVersion: '0.1.9' };
const NAME = 'EasyLens v0.1.10';
const DMG = 'https://github.com/allen-bot-ctl/EasyLens/releases/download/v0.1.10/EasyLens-0.1.10-mac-arm64.dmg';
const PAGE = 'https://github.com/allen-bot-ctl/EasyLens/releases/tag/v0.1.10';

test('状态表：自动检查 / 没有新版 不出声', () => {
  for (const state of ['idle', 'up-to-date', 'error']) {
    const view = describeTray({ state, manual: false }, CUR);
    assert.equal(view.entry.label, '检查更新…');
    assert.equal(view.entry.action, 'check');
    assert.equal(view.notification, null);
    assert.equal(view.top, null);
  }
  assert.equal(CHECK_LABEL, '检查更新…');
});

test('状态表：手动检查中 / 已是最新', () => {
  const checking = describeTray({ state: 'checking', manual: true }, CUR);
  assert.equal(checking.entry.label, '正在检查…');
  assert.equal(checking.entry.enabled, false);
  assert.equal(checking.notification, null);
  const latest = describeTray({ state: 'up-to-date', manual: true }, CUR);
  assert.equal(latest.entry.label, '检查更新…');
  assert.equal(latest.notification, '已是最新版本 0.1.9');
});

test('状态表：下载中', () => {
  const auto = describeTray({ state: 'downloading', manual: false, name: NAME }, CUR);
  assert.equal(auto.entry.label, '正在下载 0.1.10…');
  assert.equal(auto.entry.enabled, false);
  assert.equal(auto.notification, null);
  const manual = describeTray({ state: 'downloading', manual: true, name: NAME }, CUR);
  assert.equal(manual.notification, '发现新版本 0.1.10，正在下载');
});

test('状态表：已就绪，顶部加重启行，只提示一次', () => {
  const view = describeTray({ state: 'ready', manual: false, name: NAME }, CUR);
  assert.deepEqual(view.top, { label: '重启以更新到 0.1.10', action: 'install' });
  assert.equal(view.entry.label, '检查更新…');
  assert.equal(view.notification, '新版本已就绪，在托盘里点重启即可更新');
  assert.equal(view.notifyOnce, 'ready:0.1.10');
});

test('状态表：自更新失败 / sha256 失败 / 芯片不匹配', () => {
  const cases = [
    ['manual', DMG, '无法自动更新，已为你打开下载页'],
    ['checksum', DMG, '更新包校验失败，已为你打开下载页'],
    ['arch', PAGE, '无法自动更新，已为你打开下载页']
  ];
  for (const [state, url, text] of cases) {
    const auto = describeTray({ state, manual: false, name: NAME, url }, CUR);
    assert.equal(auto.entry.label, '下载新版本 0.1.10…', state);
    assert.equal(auto.entry.action, 'open');
    assert.equal(auto.entry.url, url);
    assert.equal(auto.notification, null);
    assert.equal(auto.openUrl, null);
    const manual = describeTray({ state, manual: true, name: NAME, url }, CUR);
    assert.equal(manual.notification, text, state);
    assert.equal(manual.openUrl, url);
  }
});

test('状态表：离线 / 检查失败 / 下载中断', () => {
  const view = describeTray({ state: 'error', manual: true }, CUR);
  assert.equal(view.entry.label, '检查更新…');
  assert.equal(view.notification, '检查更新失败，请稍后再试');
});

test('状态表：Win/Linux 有新版', () => {
  const auto = describeTray({ state: 'available', manual: false, name: NAME, url: PAGE }, CUR);
  assert.equal(auto.entry.label, '下载新版本 0.1.10…');
  assert.equal(auto.entry.url, PAGE);
  assert.equal(auto.notification, null);
  const manual = describeTray({ state: 'available', manual: true, name: NAME, url: PAGE }, CUR);
  assert.match(manual.notification, /0\.1\.10/);
});

test('已就绪时，自动检查失败不冲掉重启入口', () => {
  const ready = { state: 'ready', name: NAME };
  assert.equal(shouldKeepPrevious(ready, { state: 'error', manual: false }), true);
  assert.equal(shouldKeepPrevious(ready, { state: 'up-to-date', manual: false }), true);
  assert.equal(shouldKeepPrevious(ready, { state: 'error', manual: true }), false);
  assert.equal(shouldKeepPrevious({ state: 'idle' }, { state: 'error' }), false);
});

test('U-C4 更新源地址：EasyLens 两种芯片', () => {
  assert.equal(
    buildFeedUrl({ platform: 'darwin', arch: 'arm64', version: '0.1.9' }),
    'https://update.electronjs.org/allen-bot-ctl/EasyLens/darwin-arm64/0.1.9'
  );
  assert.equal(
    buildFeedUrl({ platform: 'darwin', arch: 'x64', version: '0.1.9' }),
    'https://update.electronjs.org/allen-bot-ctl/EasyLens/darwin-x64/0.1.9'
  );
  assert.equal(LATEST_RELEASE_PAGE, 'https://github.com/allen-bot-ctl/EasyLens/releases/latest');
});

test('Win/Linux 读最新 Release 判断有没有新版', () => {
  const tagUrl = (tag) => `https://github.com/allen-bot-ctl/EasyLens/releases/tag/${tag}`;
  assert.deepEqual(interpretLatestRelease(200, tagUrl('v0.1.10'), '0.1.9'), {
    state: 'available', version: '0.1.10', name: 'EasyLens v0.1.10', url: PAGE
  });
  assert.equal(interpretLatestRelease(200, tagUrl('v0.1.9'), '0.1.9').state, 'up-to-date');
  assert.equal(interpretLatestRelease(200, tagUrl('v0.1.8'), '0.1.9').state, 'up-to-date');
  assert.equal(interpretLatestRelease(404, tagUrl('v0.1.10'), '0.1.9').state, 'error');
  assert.equal(interpretLatestRelease(200, tagUrl('nightly'), '0.1.9').state, 'error');
  assert.equal(interpretLatestRelease(200, 'https://github.com/other/repo/releases/tag/v9.9.9', '0.1.9').state, 'error');
  assert.equal(interpretLatestRelease(200, 'https://github.com/allen-bot-ctl/EasyLens/releases', '0.1.9').state, 'error');
});

function waitFor(statuses, state) {
  return new Promise((resolve, reject) => {
    const deadline = Date.now() + 2000;
    (function poll() {
      if (statuses.some((s) => s.state === state)) return resolve();
      if (Date.now() > deadline) return reject(new Error(`timeout ${state}: ${JSON.stringify(statuses)}`));
      setTimeout(poll, 5);
    })();
  });
}

for (const platform of ['win32', 'linux']) {
  test(`${platform} 只检查：有新版时给 Release 页，不自更新`, async (t) => {
    const statuses = [];
    const urls = [];
    const updater = setupAutoUpdate({
      app: { isPackaged: true, getVersion: () => '0.1.9' },
      net: {
        fetch: async (url) => {
          urls.push(url);
          return { status: 200, url: PAGE };
        }
      },
      selfUpdate: { available: true, start: async () => { throw new Error('must not self-update'); } },
      onStatus: (s) => statuses.push(s),
      logger: () => {},
      platform,
      arch: 'x64',
      schedule: false
    });
    t.after(() => updater.stop());
    assert.equal(updater.mode, 'check-only');
    updater.checkNow({ manual: true });
    await waitFor(statuses, 'available');
    assert.deepEqual(statuses.map((s) => s.state), ['checking', 'available']);
    assert.equal(statuses.at(-1).url, PAGE);
    assert.deepEqual(urls, [LATEST_RELEASE_PAGE]);
  });
}

test('开发态（未打包）不检查更新', () => {
  const updater = setupAutoUpdate({
    app: { isPackaged: false, getVersion: () => '0.1.9' },
    net: { fetch: async () => { throw new Error('no network in dev'); } },
    platform: 'linux',
    schedule: false
  });
  assert.equal(updater.mode, 'disabled');
});
