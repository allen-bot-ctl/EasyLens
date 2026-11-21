'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { setupAutoUpdate } = require('../electron/updater');

const FINAL_STATES = new Set(['up-to-date', 'manual', 'error']);

function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'easylens-updater-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function makeApp(dir) {
  return {
    isPackaged: true,
    getVersion: () => '0.1.3',
    getPath: () => dir
  };
}

function makeAutoUpdater() {
  const state = { setFeedUrlCalls: 0 };
  return {
    state,
    setFeedURL() {
      state.setFeedUrlCalls += 1;
      throw new Error('setFeedURL must not be called on macOS');
    }
  };
}

function feedResponse(status, payload) {
  return {
    status,
    json: async () => payload
  };
}

function makeNotifiedStore() {
  const keys = new Set();
  return {
    keys,
    isNotified: (key) => keys.has(key),
    markNotified: (key) => keys.add(key)
  };
}

function makeCollector() {
  const statuses = [];
  const waiters = [];

  function notify() {
    for (const waiter of [...waiters]) waiter();
  }

  function onStatus(status) {
    statuses.push(status);
    notify();
  }

  function waitForFinal(count = 1) {
    return new Promise((resolve, reject) => {
      let timer = null;

      const cleanup = () => {
        if (timer) clearTimeout(timer);
        const index = waiters.indexOf(check);
        if (index >= 0) waiters.splice(index, 1);
      };

      const check = () => {
        const finals = statuses.filter((status) => FINAL_STATES.has(status.state));
        if (finals.length >= count) {
          cleanup();
          resolve();
        }
      };

      timer = setTimeout(() => {
        cleanup();
        reject(new Error(`timed out; statuses=${JSON.stringify(statuses)}`));
      }, 2000);

      waiters.push(check);
      check();
    });
  }

  return { statuses, onStatus, waitForFinal };
}

function setupProbeOnly(t, options = {}) {
  const dir = tempDir(t);
  const app = makeApp(dir);
  const autoUpdater = makeAutoUpdater();
  const collector = makeCollector();
  const logs = [];
  const manualCalls = [];
  const notified = makeNotifiedStore();

  const updater = setupAutoUpdate({
    app,
    autoUpdater,
    net: { fetch: options.fetch },
    onStatus: collector.onStatus,
    onManual: (payload) => manualCalls.push(payload),
    onReady: () => {},
    isNotified: notified.isNotified,
    markNotified: notified.markNotified,
    logger: (message) => logs.push(message),
    platform: 'darwin',
    arch: 'x64',
    schedule: false
  });

  t.after(() => updater.stop());

  return {
    dir,
    app,
    autoUpdater,
    collector,
    logs,
    manualCalls,
    notified,
    updater
  };
}

test('macOS always enters probe-only mode without calling setFeedURL', async (t) => {
  const env = setupProbeOnly(t, {
    fetch: async () => feedResponse(204, null)
  });

  assert.notEqual(env.updater, null);
  assert.equal(env.updater.mode, 'probe-only');
  assert.equal(env.autoUpdater.state.setFeedUrlCalls, 0);
  assert.match(env.logs.join('\n'), /macOS 未正式签名，使用 probe-only/);
  assert.match(env.updater.feedUrl, /darwin-x64\/0\.1\.3$/);

  const immediate = env.updater.checkNow({ manual: true });
  assert.equal(immediate.state, 'checking');
  assert.equal(env.autoUpdater.state.setFeedUrlCalls, 0);

  await env.collector.waitForFinal(1);

  assert.equal(env.autoUpdater.state.setFeedUrlCalls, 0);
  assert.deepEqual(
    env.collector.statuses.map((status) => [status.state, status.manual]),
    [
      ['checking', true],
      ['up-to-date', true]
    ]
  );
  assert.match(env.logs.join('\n'), /manual check start/);
  assert.match(env.logs.join('\n'), /manual check result: up-to-date/);
});

test('probe-only mode reports a manual download once for a 200 feed payload', async (t) => {
  const env = setupProbeOnly(t, {
    fetch: async () => feedResponse(200, {
      name: 'EasyLens v0.1.4',
      url: 'https://example.invalid/EasyLens-0.1.4-mac-x64.zip'
    })
  });

  env.updater.checkNow({ manual: true });
  await env.collector.waitForFinal(1);

  const final = env.collector.statuses.at(-1);
  assert.equal(final.state, 'manual');
  assert.equal(final.manual, true);
  assert.equal(final.name, 'EasyLens v0.1.4');
  assert.equal(
    final.url,
    'https://github.com/allen-bot-ctl/EasyLens/releases/download/v0.1.4/EasyLens-0.1.4-mac-x64.dmg'
  );
  assert.equal(env.manualCalls.length, 1);
  assert.deepEqual(env.manualCalls[0], {
    name: 'EasyLens v0.1.4',
    url: 'https://github.com/allen-bot-ctl/EasyLens/releases/download/v0.1.4/EasyLens-0.1.4-mac-x64.dmg'
  });
  assert.match(env.logs.join('\n'), /manual check result: manual/);
});

test('probe-only mode reports error when the feed fetch rejects', async (t) => {
  const env = setupProbeOnly(t, {
    fetch: async () => {
      throw new Error('network down');
    }
  });

  env.updater.checkNow({ manual: true });
  await env.collector.waitForFinal(1);

  const final = env.collector.statuses.at(-1);
  assert.equal(final.state, 'error');
  assert.equal(final.manual, true);
  assert.match(env.logs.join('\n'), /feed probe failed: network down/);
  assert.match(env.logs.join('\n'), /manual check result: error/);
});

test('concurrent manual clicks share one feed probe but both get a final state', async (t) => {
  let fetchCalls = 0;
  let resolveFetch = null;
  const pendingFetch = new Promise((resolve) => {
    resolveFetch = resolve;
  });

  const env = setupProbeOnly(t, {
    fetch: () => {
      fetchCalls += 1;
      return pendingFetch;
    }
  });

  env.updater.checkNow({ manual: true });
  env.updater.checkNow({ manual: true });

  assert.equal(fetchCalls, 1);

  resolveFetch(feedResponse(204, null));
  await env.collector.waitForFinal(2);

  assert.equal(fetchCalls, 1);
  const finals = env.collector.statuses.filter((status) => FINAL_STATES.has(status.state));
  assert.equal(finals.length, 2);
  assert.ok(finals.every((status) => status.state === 'up-to-date' && status.manual === true));
});
