'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const {
  INSTALL_SCRIPT,
  SUPPORTED_ARCHES,
  classifyFailure,
  deriveReleasePageUrl,
  compareSemver,
  deriveDmgUrl,
  extractVersion,
  parseSha256File,
  parseUpdateUrl,
  resolveBundlePath,
  createMacSelfUpdater
} = require('../electron/mac-self-update');
const { setupAutoUpdate } = require('../electron/updater');

const APP_VERSION = '0.1.5';
const NEXT_VERSION = '0.1.6';

function tempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'easylens-self-update-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function updateFor(version, overrides = {}) {
  return {
    name: `EasyLens v${version}`,
    url: `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${version}/EasyLens-${version}-mac-x64.zip`,
    ...overrides
  };
}

function makeBundle(t) {
  const parent = tempDir(t);
  const bundlePath = path.join(parent, 'EasyLens.app');
  const macos = path.join(bundlePath, 'Contents', 'MacOS');
  fs.mkdirSync(macos, { recursive: true });
  const execPath = path.join(macos, 'EasyLens');
  fs.writeFileSync(execPath, '');
  return { parent, bundlePath, execPath };
}

function sha256(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex');
}

function textResponse(text, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => String(Buffer.byteLength(text)) },
    text: async () => text,
    arrayBuffer: async () => new Uint8Array(Buffer.from(text)).buffer
  };
}

function binaryResponse(buffer, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: () => String(buffer.length) },
    text: async () => buffer.toString('utf8'),
    arrayBuffer: async () => new Uint8Array(buffer).buffer
  };
}

function makeFetch(routes) {
  const calls = [];
  async function fetchImpl(url, init) {
    calls.push({ url, init });
    const route = routes[url];
    if (route === undefined) return textResponse('', 404);
    if (typeof route === 'function') return route(url, init);
    if (Buffer.isBuffer(route)) return binaryResponse(route);
    if (typeof route === 'string') return textResponse(route);
    return textResponse(route.text || '', route.status || 200);
  }
  return { fetchImpl, calls };
}

function createExtractedApp(destination, version, executable = 'EasyLens') {
  const appDir = path.join(destination, 'EasyLens.app');
  fs.mkdirSync(path.join(appDir, 'Contents', 'MacOS'), { recursive: true });
  fs.writeFileSync(path.join(appDir, 'Contents', 'Info.plist'), '<plist/>');
  fs.writeFileSync(path.join(appDir, 'Contents', 'MacOS', executable), '');
  return { appDir, version };
}

function makeExecFile(options = {}) {
  const calls = [];
  const plistVersion = options.plistVersion || NEXT_VERSION;
  const executable = options.executable || 'EasyLens';

  const execFile = (file, args, execOptions, callback) => {
    calls.push({ file, args, options: execOptions });
    try {
      if (file === '/usr/bin/ditto') {
        const destination = args[3];
        createExtractedApp(destination, plistVersion);
        callback(null, '', '');
        return;
      }
      if (file === '/usr/bin/plutil') {
        const key = args[1];
        if (key === 'CFBundleShortVersionString') {
          callback(null, `${plistVersion}\n`, '');
          return;
        }
        if (key === 'CFBundleExecutable') {
          callback(null, `${executable}\n`, '');
          return;
        }
      }
      if (file === '/usr/bin/file') {
        if (options.fileOutput === undefined) {
          callback(new Error('file not available in tests'));
        } else {
          callback(null, options.fileOutput, '');
        }
        return;
      }
      if (file === '/usr/bin/xattr') {
        callback(null, '', '');
        return;
      }
      callback(new Error(`unexpected execFile: ${file}`));
    } catch (error) {
      callback(error);
    }
  };

  return { execFile, calls };
}

function makeSelfUpdater(context, overrides = {}) {
  const logs = [];
  const quits = [];
  const spawnCalls = [];
  const updater = createMacSelfUpdater({
    appVersion: APP_VERSION,
    arch: 'x64',
    platform: 'darwin',
    isPackaged: true,
    execPath: context.bundle.execPath,
    fetch: context.fetch,
    execFile: context.execFile,
    spawn: (file, args, spawnOptions) => {
      spawnCalls.push({ file, args, options: spawnOptions });
      return { unref() {} };
    },
    fs,
    path,
    logger: (message) => logs.push(message),
    logsDir: context.logsDir,
    pid: 4321,
    quit: () => quits.push(true),
    ...overrides
  });
  return { updater, logs, quits, spawnCalls };
}

function fullEnvironment(t, options = {}) {
  const bundle = makeBundle(t);
  const version = options.version || NEXT_VERSION;
  const update = options.update || updateFor(version);
  const zipContent = Buffer.from('fake release zip body');
  const zipName = path.basename(new URL(update.url).pathname);
  const digest = sha256(options.zipContent || zipContent);
  const routes = {
    [update.url]: options.zipContent || zipContent,
    [`${update.url}.sha256`]: {
      text: options.shaText || `${digest}  ${zipName}`
    }
  };
  if (options.shaMissing) delete routes[`${update.url}.sha256`];

  const { fetchImpl, calls } = makeFetch(options.routes || routes);
  const exec = makeExecFile({
    plistVersion: options.plistVersion || version,
    executable: options.executable,
    fileOutput: options.fileOutput
  });
  const env = {
    bundle,
    update,
    zipContent,
    fetchImpl,
    fetchCalls: calls,
    execFile: exec.execFile,
    execCalls: exec.calls,
    logsDir: path.join(bundle.parent, 'logs')
  };
  return env;
}

test('parseUpdateUrl accepts the exact GitHub release asset shape', () => {
  const update = updateFor(NEXT_VERSION);
  const parsed = parseUpdateUrl(update, {
    arch: 'x64',
    appVersion: APP_VERSION
  });

  assert.equal(parsed.ok, true);
  assert.equal(parsed.version, NEXT_VERSION);
  assert.equal(parsed.filename, `EasyLens-${NEXT_VERSION}-mac-x64.zip`);
  assert.equal(parsed.url, update.url);
  assert.equal(
    parsed.dmgUrl,
    `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-x64.dmg`
  );
  assert.equal(parsed.name, `EasyLens v${NEXT_VERSION}`);
});

test('parseUpdateUrl rejects bad hosts, repositories, schemes and asset names', () => {
  const options = { arch: 'x64', appVersion: APP_VERSION };
  const good = updateFor(NEXT_VERSION).url;

  const badUrls = [
    good.replace('https://github.com', 'http://github.com'),
    good.replace('https://github.com', 'https://evil.example'),
    good.replace('/allen-bot-ctl/EasyLens/', '/other/repo/'),
    good.replace('/allen-bot-ctl/EasyLens/', '/allen-bot-ctl/other/'),
    `${good}?download=1`,
    good.replace(`EasyLens-${NEXT_VERSION}-mac-x64.zip`, `EasyLens-${NEXT_VERSION}-mac-x64.dmg`),
    good.replace('/download/v0.1.6/', '/download/v0.1.7/'),
    good.replace(`EasyLens-${NEXT_VERSION}`, 'EasyLens-0.1.5')
  ];

  for (const url of badUrls) {
    const parsed = parseUpdateUrl({ name: 'x', url }, options);
    assert.equal(parsed.ok, false, url);
  }

  assert.equal(parseUpdateUrl({ name: 'x', url: '' }, options).reason, 'missing-url');
  assert.equal(
    parseUpdateUrl({ name: 'x', url: 'not a url' }, options).reason,
    'invalid-url'
  );
});

test('parseUpdateUrl rejects a zip whose arch differs from this machine', () => {
  const arm64Url = updateFor(NEXT_VERSION).url.replace('-mac-x64.zip', '-mac-arm64.zip');
  assert.equal(
    parseUpdateUrl({ url: arm64Url }, { arch: 'x64', appVersion: APP_VERSION }).reason,
    'unsupported-arch'
  );
  assert.equal(
    parseUpdateUrl(updateFor(NEXT_VERSION), { arch: 'arm64', appVersion: APP_VERSION }).reason,
    'unsupported-arch'
  );
});

test('parseUpdateUrl rejects equal, older and malformed versions', () => {
  for (const version of ['0.1.5', '0.1.4']) {
    const parsed = parseUpdateUrl(updateFor(version), {
      arch: 'x64',
      appVersion: APP_VERSION
    });
    assert.equal(parsed.ok, false);
    assert.equal(parsed.reason, 'not-newer');
    assert.equal(parsed.version, version);
  }

  assert.equal(
    parseUpdateUrl({ url: updateFor(NEXT_VERSION).url.replace('v0.1.6', 'v0.1') }, {
      arch: 'x64',
      appVersion: APP_VERSION
    }).ok,
    false
  );
});

test('compareSemver orders versions and rejects invalid values', () => {
  assert.equal(compareSemver('0.1.6', '0.1.5'), 1);
  assert.equal(compareSemver('0.1.5', '0.1.6'), -1);
  assert.equal(compareSemver('1.0.0', '0.9.9'), 1);
  assert.equal(compareSemver('0.1.6', '0.1.6'), 0);
  assert.equal(compareSemver('v0.1.6', '0.1.5'), null);
  assert.equal(compareSemver('0.1', '0.1.5'), null);
  assert.equal(compareSemver(null, '0.1.5'), null);
});

test('deriveDmgUrl builds the direct DMG asset URL', () => {
  assert.equal(
    deriveDmgUrl(NEXT_VERSION, 'x64'),
    `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-x64.dmg`
  );
  assert.equal(
    deriveDmgUrl(NEXT_VERSION, 'arm64'),
    `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-arm64.dmg`
  );
  assert.equal(deriveDmgUrl(`v${NEXT_VERSION}`, 'x64'), deriveDmgUrl(NEXT_VERSION, 'x64'));
  assert.equal(deriveDmgUrl('0.1'), null);
  assert.equal(deriveDmgUrl(''), null);
});

test('extractVersion reads strict versions from names and URLs', () => {
  assert.equal(extractVersion('EasyLens v0.1.6'), '0.1.6');
  assert.equal(extractVersion('https://x/v0.1.6/file.zip'), '0.1.6');
  assert.equal(extractVersion('no version'), null);
  assert.equal(extractVersion(null), null);
});

test('parseSha256File accepts with or without a matching filename', () => {
  const digest = 'a'.repeat(64);
  assert.equal(parseSha256File(digest, 'x.zip'), digest);
  assert.equal(parseSha256File(`${digest}  x.zip`, 'x.zip'), digest);
  assert.equal(parseSha256File(`${digest.toUpperCase()} x.zip`, 'x.zip'), digest);
  assert.equal(parseSha256File(`\n${digest}  x.zip\n`, 'x.zip'), digest);
  assert.equal(parseSha256File(`${digest}  other.zip`, 'x.zip'), null);
  assert.equal(parseSha256File('not-a-digest  x.zip', 'x.zip'), null);
  assert.equal(parseSha256File('', 'x.zip'), null);
});

test('resolveBundlePath accepts writable .app bundles and refuses translocated paths', (t) => {
  const bundle = makeBundle(t);
  const resolved = resolveBundlePath({ execPath: bundle.execPath, fs, path });
  assert.equal(resolved.ok, true);
  assert.equal(resolved.bundlePath, bundle.bundlePath);
  assert.equal(resolved.parent, bundle.parent);

  const translocated = resolveBundlePath({
    execPath: `/private/var/folders/x/AppTranslocation/ABC/d/EasyLens.app/Contents/MacOS/EasyLens`,
    fs,
    path
  });
  assert.equal(translocated.ok, false);
  assert.equal(translocated.reason, 'translocated');

  const notApp = resolveBundlePath({
    execPath: path.join(bundle.parent, 'EasyLens', 'Contents', 'MacOS', 'EasyLens'),
    fs,
    path
  });
  assert.equal(notApp.ok, false);
  assert.equal(notApp.reason, 'not-an-app-bundle');
});

test('resolveBundlePath refuses an unwritable parent or bundle', (t) => {
  const bundle = makeBundle(t);
  const deniedFs = {
    constants: fs.constants,
    accessSync() {
      const error = new Error('EACCES');
      error.code = 'EACCES';
      throw error;
    }
  };
  const resolved = resolveBundlePath({
    execPath: bundle.execPath,
    fs: deniedFs,
    path
  });
  assert.equal(resolved.ok, false);
  assert.equal(resolved.reason, 'not-writable');
});

test('self-update downloads, verifies, extracts and reuses the staged bundle', async (t) => {
  const env = fullEnvironment(t);
  const context = {
    bundle: env.bundle,
    fetch: env.fetchImpl,
    execFile: env.execFile,
    logsDir: env.logsDir
  };
  const { updater, logs } = makeSelfUpdater(context);

  assert.equal(updater.available, true);
  const first = await updater.start(env.update);
  assert.equal(first.ok, true, first.reason);
  assert.equal(first.version, NEXT_VERSION);
  assert.equal(first.reused, false);
  assert.ok(first.newApp.endsWith('EasyLens.app'));
  assert.ok(fs.existsSync(path.join(first.staging, 'verified.json')));
  assert.equal(
    env.fetchCalls.filter((call) => call.url === env.update.url).length,
    1
  );

  const second = await updater.start(env.update);
  assert.equal(second.ok, true, second.reason);
  assert.equal(second.reused, true);
  assert.equal(
    env.fetchCalls.filter((call) => call.url === env.update.url).length,
    1,
    'verified staging must be reused without downloading again'
  );
  assert.match(logs.join('\n'), /reusing verified staged update/);
});

test('self-update falls back on sha256 mismatch', async (t) => {
  const env = fullEnvironment(t, { shaText: `${'0'.repeat(64)}  EasyLens-0.1.6-mac-x64.zip` });
  const context = {
    bundle: env.bundle,
    fetch: env.fetchImpl,
    execFile: env.execFile,
    logsDir: env.logsDir
  };
  const { updater, logs } = makeSelfUpdater(context);

  const result = await updater.start(env.update);
  assert.equal(result.ok, false);
  assert.match(result.reason, /sha256-mismatch/);
  assert.equal(result.version, NEXT_VERSION);
  assert.match(logs.join('\n'), /sha256-mismatch/);
});

test('self-update falls back when the sha256 asset is missing or has the wrong filename', async (t) => {
  const missing = fullEnvironment(t, { shaMissing: true });
  const missingUpdater = makeSelfUpdater({
    bundle: missing.bundle,
    fetch: missing.fetchImpl,
    execFile: missing.execFile,
    logsDir: missing.logsDir
  }).updater;
  const missingResult = await missingUpdater.start(missing.update);
  assert.equal(missingResult.ok, false);
  assert.match(missingResult.reason, /sha256-download-status-404/);

  const wrongName = fullEnvironment(t, {
    shaText: `${sha256(Buffer.from('fake release zip body'))}  other.zip`
  });
  const wrongUpdater = makeSelfUpdater({
    bundle: wrongName.bundle,
    fetch: wrongName.fetchImpl,
    execFile: wrongName.execFile,
    logsDir: wrongName.logsDir
  }).updater;
  const wrongResult = await wrongUpdater.start(wrongName.update);
  assert.equal(wrongResult.ok, false);
  assert.equal(wrongResult.reason, 'sha256-missing-or-invalid');
});

test('self-update falls back on a plist version mismatch or missing executable', async (t) => {
  const mismatched = fullEnvironment(t, { plistVersion: '9.9.9' });
  const mismatchedUpdater = makeSelfUpdater({
    bundle: mismatched.bundle,
    fetch: mismatched.fetchImpl,
    execFile: mismatched.execFile,
    logsDir: mismatched.logsDir
  }).updater;
  const mismatchResult = await mismatchedUpdater.start(mismatched.update);
  assert.equal(mismatchResult.ok, false);
  assert.match(mismatchResult.reason, /plist-version-mismatch/);

  const missingExecutable = fullEnvironment(t);
  const missingExecutableUpdater = makeSelfUpdater({
    bundle: missingExecutable.bundle,
    fetch: missingExecutable.fetchImpl,
    execFile: makeExecFile({
      plistVersion: NEXT_VERSION,
      executable: 'missing-binary'
    }).execFile,
    logsDir: missingExecutable.logsDir
  }).updater;
  const missingResult = await missingExecutableUpdater.start(missingExecutable.update);
  assert.equal(missingResult.ok, false);
  assert.match(missingResult.reason, /bundle-executable-missing/);
});

test('self-update aborts downloads above the size limit', async (t) => {
  const env = fullEnvironment(t);
  const context = {
    bundle: env.bundle,
    fetch: env.fetchImpl,
    execFile: env.execFile,
    logsDir: env.logsDir
  };
  const { updater } = makeSelfUpdater(context, { maxDownloadBytes: 4 });
  const result = await updater.start(env.update);
  assert.equal(result.ok, false);
  assert.match(result.reason, /download-too-large/);
});

test('self-update refuses translocated and unwritable app bundles', async (t) => {
  const env = fullEnvironment(t);
  const base = {
    bundle: env.bundle,
    fetch: env.fetchImpl,
    execFile: env.execFile,
    logsDir: env.logsDir
  };

  const translocated = makeSelfUpdater(base, {
    execPath: '/private/var/folders/x/AppTranslocation/ABC/d/EasyLens.app/Contents/MacOS/EasyLens'
  }).updater;
  const translocatedResult = await translocated.start(env.update);
  assert.equal(translocatedResult.ok, false);
  assert.equal(translocatedResult.reason, 'translocated');

  const deniedFs = {
    constants: fs.constants,
    accessSync() {
      const error = new Error('EACCES');
      error.code = 'EACCES';
      throw error;
    }
  };
  const unwritable = makeSelfUpdater(base, { fs: deniedFs }).updater;
  const unwritableResult = await unwritable.start(env.update);
  assert.equal(unwritableResult.ok, false);
  assert.equal(unwritableResult.reason, 'not-writable');
  assert.equal(
    env.fetchCalls.filter((call) => call.url === env.update.url).length,
    0,
    'bundle validation must run before any network request'
  );
});

test('only one self-update job is in flight at a time', async (t) => {
  const bundle = makeBundle(t);
  const update = updateFor(NEXT_VERSION);
  const zipContent = Buffer.from('fake release zip body');
  const zipName = path.basename(new URL(update.url).pathname);
  const digest = sha256(zipContent);
  let resolveZip = null;
  let zipCalls = 0;

  const fetchImpl = async (url) => {
    if (url === update.url) {
      zipCalls += 1;
      return new Promise((resolve) => {
        resolveZip = () => resolve(binaryResponse(zipContent));
      });
    }
    if (url === `${update.url}.sha256`) {
      return textResponse(`${digest}  ${zipName}`);
    }
    return textResponse('', 404);
  };

  const exec = makeExecFile({ plistVersion: NEXT_VERSION });
  const { updater } = makeSelfUpdater({
    bundle,
    fetch: fetchImpl,
    execFile: exec.execFile,
    logsDir: path.join(bundle.parent, 'logs')
  });

  const first = updater.start(update);
  const second = updater.start(update);
  assert.equal(first, second, 'concurrent starts must return the same promise');
  assert.equal(zipCalls, 1, 'only one zip download may start');

  resolveZip();
  const [one, two] = await Promise.all([first, second]);
  assert.equal(one.ok, true, one.reason);
  assert.equal(two.ok, true, two.reason);
  assert.equal(zipCalls, 1);
});

test('install script is static, positional and contains wait plus rollback', () => {
  assert.match(INSTALL_SCRIPT, /while kill -0 "\$PID" 2>\/dev\/null; do/);
  assert.match(INSTALL_SCRIPT, /if \[ "\$waited" -ge 60 \]/);
  assert.match(INSTALL_SCRIPT, /mv "\$BACKUP" "\$BUNDLE"/);
  assert.match(INSTALL_SCRIPT, /\/usr\/bin\/open -n "\$BUNDLE"/);
  assert.match(INSTALL_SCRIPT, /\$1/);
  assert.match(INSTALL_SCRIPT, /\$5/);
  assert.doesNotMatch(INSTALL_SCRIPT, /\/Applications/);
  assert.doesNotMatch(INSTALL_SCRIPT, /easylens-self-update-/);

  const backupFailure = INSTALL_SCRIPT.slice(
    INSTALL_SCRIPT.indexOf('failed to move current app to backup'),
    INSTALL_SCRIPT.indexOf('moving new app into place')
  );
  assert.match(backupFailure, /\/usr\/bin\/open -n "\$BUNDLE"/);
  assert.match(backupFailure, /exit 1/);
  assert.ok(
    backupFailure.indexOf('/usr/bin/open -n "$BUNDLE"') <
      backupFailure.indexOf('exit 1'),
    'the old app must be reopened before the backup-failure exit'
  );
});

test('install script passes /bin/sh syntax check', { skip: process.platform === 'win32' && '/bin/sh 不存在于 Windows' }, (t) => {
  const dir = tempDir(t);
  const scriptPath = path.join(dir, 'update-install.sh');
  fs.writeFileSync(scriptPath, INSTALL_SCRIPT, { mode: 0o700 });

  const result = spawnSync('/bin/sh', ['-n', scriptPath], { encoding: 'utf8' });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
});

test('installReady writes the static script and passes all paths as arguments', async (t) => {
  const env = fullEnvironment(t);
  const context = {
    bundle: env.bundle,
    fetch: env.fetchImpl,
    execFile: env.execFile,
    logsDir: env.logsDir
  };
  const { updater, quits, spawnCalls } = makeSelfUpdater(context);

  const ready = await updater.start(env.update);
  assert.equal(ready.ok, true, ready.reason);

  const installed = updater.installReady();
  assert.equal(installed.ok, true, installed.reason);
  assert.equal(quits.length, 1);
  assert.equal(spawnCalls.length, 1);

  const spawn = spawnCalls[0];
  assert.equal(spawn.file, '/bin/sh');
  assert.equal(spawn.args[0], path.join(ready.staging, 'update-install.sh'));
  assert.deepEqual(spawn.args.slice(1), [
    '4321',
    ready.bundlePath,
    ready.newApp,
    path.join(ready.parent, `.EasyLens-backup-${NEXT_VERSION}.app`),
    ready.staging
  ]);
  assert.equal(spawn.options.detached, true);
  assert.equal(spawn.options.stdio[0], 'ignore');
  assert.equal(typeof spawn.options.stdio[1], 'number');

  const script = fs.readFileSync(spawn.args[0], 'utf8');
  assert.equal(script, INSTALL_SCRIPT);
  assert.ok(!script.includes(ready.bundlePath));
  assert.ok(!script.includes(ready.newApp));
  assert.ok(!script.includes(ready.staging));
  assert.ok(fs.existsSync(installed.installLog));
  assert.equal(updater.lastReady, null);
});

function makeCollector() {
  const statuses = [];
  return {
    statuses,
    onStatus(status) {
      statuses.push(status);
    },
    async waitFor(state) {
      const deadline = Date.now() + 2000;
      while (Date.now() < deadline) {
        if (statuses.some((status) => status.state === state)) return;
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      throw new Error(`timed out waiting for ${state}: ${JSON.stringify(statuses)}`);
    }
  };
}

function makeAutoUpdater() {
  return {
    setFeedURL() {
      throw new Error('Could not get code signature for running application');
    },
    on() {},
    checkForUpdates() {}
  };
}

function makeProbeApp() {
  return {
    isPackaged: true,
    getVersion: () => APP_VERSION,
    getPath: () => os.tmpdir()
  };
}

test('probe-only mode emits downloading then ready for a self-updatable release', async (t) => {
  const collector = makeCollector();
  const readyCalls = [];
  const manualCalls = [];
  const selfUpdateCalls = [];
  const update = updateFor(NEXT_VERSION);

  const updater = setupAutoUpdate({
    app: makeProbeApp(),
    autoUpdater: makeAutoUpdater(),
    net: {
      fetch: async () => ({
        status: 200,
        json: async () => update
      })
    },
    selfUpdate: {
      available: true,
      start: async (payload) => {
        selfUpdateCalls.push(payload);
        return {
          ok: true,
          mode: 'ready-self',
          version: NEXT_VERSION,
          name: payload.name,
          newApp: '/tmp/new/EasyLens.app',
          staging: '/tmp/stage'
        };
      }
    },
    onStatus: collector.onStatus,
    onReady: (payload) => readyCalls.push(payload),
    onManual: (payload) => manualCalls.push(payload),
    logger: () => {},
    platform: 'darwin',
    arch: 'x64',
    schedule: false
  });
  t.after(() => updater.stop());

  updater.checkNow({ manual: true });
  await collector.waitFor('ready');

  assert.deepEqual(
    collector.statuses.map((status) => status.state),
    ['checking', 'downloading', 'ready']
  );
  assert.deepEqual(selfUpdateCalls, [update]);
  assert.deepEqual(readyCalls, [{ name: update.name, mode: 'ready-self' }]);
  assert.equal(manualCalls.length, 0);
  const ready = collector.statuses.at(-1);
  assert.equal(ready.manual, true);
  assert.equal(ready.selfUpdate, true);
});

test('probe-only mode falls back to the direct DMG when self-update fails', async (t) => {
  const collector = makeCollector();
  const manualCalls = [];
  const notified = new Set();
  const update = updateFor(NEXT_VERSION);

  const updater = setupAutoUpdate({
    app: makeProbeApp(),
    autoUpdater: makeAutoUpdater(),
    net: {
      fetch: async () => ({
        status: 200,
        json: async () => update
      })
    },
    selfUpdate: {
      available: true,
      start: async () => ({
        ok: false,
        reason: 'not-writable',
        version: NEXT_VERSION
      })
    },
    onStatus: collector.onStatus,
    onReady: () => {},
    onManual: (payload) => manualCalls.push(payload),
    isNotified: (key) => notified.has(key),
    markNotified: (key) => notified.add(key),
    logger: () => {},
    platform: 'darwin',
    arch: 'x64',
    schedule: false
  });
  t.after(() => updater.stop());

  updater.checkNow({ manual: true });
  await collector.waitFor('manual');

  assert.deepEqual(
    collector.statuses.map((status) => status.state),
    ['checking', 'downloading', 'manual']
  );
  const expectedUrl =
    `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-x64.dmg`;
  assert.deepEqual(manualCalls, [{ name: update.name, url: expectedUrl }]);
  assert.equal(collector.statuses.at(-1).url, expectedUrl);
});

// ---- 0.1.9 EasyLens：x64 + arm64、文件名正则、sha256 回退、芯片不匹配、下载中断 ----

function armUpdateFor(version) {
  return {
    name: `EasyLens v${version}`,
    url: `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${version}/EasyLens-${version}-mac-arm64.zip`
  };
}

test('U-C1 both x64 and arm64 pick the zip matching process.arch', () => {
  assert.deepEqual([...SUPPORTED_ARCHES], ['x64', 'arm64']);
  const x64 = parseUpdateUrl(updateFor(NEXT_VERSION), { arch: 'x64', appVersion: APP_VERSION });
  assert.equal(x64.ok, true, x64.reason);
  assert.equal(x64.arch, 'x64');
  assert.equal(x64.filename, `EasyLens-${NEXT_VERSION}-mac-x64.zip`);
  assert.equal(x64.dmgUrl, `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-x64.dmg`);

  const arm = parseUpdateUrl(armUpdateFor(NEXT_VERSION), { arch: 'arm64', appVersion: APP_VERSION });
  assert.equal(arm.ok, true, arm.reason);
  assert.equal(arm.arch, 'arm64');
  assert.equal(arm.filename, `EasyLens-${NEXT_VERSION}-mac-arm64.zip`);
  assert.equal(arm.dmgUrl, `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-arm64.dmg`);

  // 芯片不匹配：Release 缺本机芯片的 zip，更新源退回另一种芯片的包。
  assert.equal(parseUpdateUrl(updateFor(NEXT_VERSION), { arch: 'arm64', appVersion: APP_VERSION }).reason, 'unsupported-arch');
  assert.equal(parseUpdateUrl(armUpdateFor(NEXT_VERSION), { arch: 'x64', appVersion: APP_VERSION }).reason, 'unsupported-arch');
  assert.equal(parseUpdateUrl(updateFor(NEXT_VERSION), { arch: 'ia32', appVersion: APP_VERSION }).reason, 'unsupported-arch');
});

test('U-C1 update file regex only accepts EasyLens-<semver>-mac-(x64|arm64).zip', () => {
  const base = `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/`;
  const options = { arch: 'x64', appVersion: APP_VERSION };
  for (const bad of [
    `LanLi-${NEXT_VERSION}-mac-x64.zip`,
    `EasyLens-${NEXT_VERSION}-mac-universal.zip`,
    `EasyLens-${NEXT_VERSION}-mac-x64.dmg`,
    `EasyLens-${NEXT_VERSION}-linux-x64.zip`,
    `easylens-${NEXT_VERSION}-mac-x64.zip`
  ]) {
    assert.equal(parseUpdateUrl({ url: base + bad }, options).reason, 'unexpected-asset-name', bad);
  }
});

test('deriveDmgUrl follows the machine arch and the Release page is the arch fallback', () => {
  assert.match(deriveDmgUrl(NEXT_VERSION, 'arm64'), /EasyLens-0\.1\.6-mac-arm64\.dmg$/);
  assert.match(deriveDmgUrl(NEXT_VERSION, 'x64'), /EasyLens-0\.1\.6-mac-x64\.dmg$/);
  assert.equal(deriveDmgUrl(NEXT_VERSION, 'ia32'), null);
  assert.equal(deriveReleasePageUrl(NEXT_VERSION), 'https://github.com/allen-bot-ctl/EasyLens/releases/tag/v0.1.6');
  assert.equal(deriveReleasePageUrl('x'), 'https://github.com/allen-bot-ctl/EasyLens/releases/latest');
});

test('classifyFailure maps reasons onto the contract state table', () => {
  assert.equal(classifyFailure('unsupported-arch'), 'arch');
  assert.equal(classifyFailure('arch-mismatch: expected arm64, got x'), 'arch');
  assert.equal(classifyFailure('sha256-mismatch: expected a, got b'), 'checksum');
  assert.equal(classifyFailure('sha256-missing-or-invalid'), 'checksum');
  assert.equal(classifyFailure('zip-download-failed: socket hang up'), 'offline');
  assert.equal(classifyFailure('sha256-download-failed: ENOTFOUND'), 'offline');
  assert.equal(classifyFailure('zip-download-status-503'), 'offline');
  assert.equal(classifyFailure('not-writable'), 'manual');
  assert.equal(classifyFailure('translocated'), 'manual');
  assert.equal(classifyFailure('zip-download-status-404'), 'manual');
});

test('arm64 self-update downloads the arm64 zip and stages it', async (t) => {
  const update = armUpdateFor(NEXT_VERSION);
  const env = fullEnvironment(t, { update, fileOutput: 'Mach-O 64-bit executable arm64\n' });
  const { updater } = makeSelfUpdater({
    bundle: env.bundle, fetch: env.fetchImpl, execFile: env.execFile, logsDir: env.logsDir
  }, { arch: 'arm64' });
  assert.equal(updater.available, true);
  const result = await updater.start(update);
  assert.equal(result.ok, true, result.reason);
  assert.ok(env.fetchCalls.some((call) => call.url.endsWith('EasyLens-0.1.6-mac-arm64.zip')));
  assert.ok(env.fetchCalls.some((call) => call.url.endsWith('EasyLens-0.1.6-mac-arm64.zip.sha256')));
});

test('sha256 mismatch deletes the downloaded zip', async (t) => {
  const env = fullEnvironment(t, { shaText: `${'0'.repeat(64)}  EasyLens-0.1.6-mac-x64.zip` });
  const { updater } = makeSelfUpdater({
    bundle: env.bundle, fetch: env.fetchImpl, execFile: env.execFile, logsDir: env.logsDir
  });
  const result = await updater.start(env.update);
  assert.equal(result.ok, false);
  assert.equal(classifyFailure(result.reason), 'checksum');
  const staging = path.join(env.bundle.parent, `.EasyLens-update-${NEXT_VERSION}`);
  assert.equal(fs.existsSync(path.join(staging, 'EasyLens-0.1.6-mac-x64.zip')), false);
  assert.equal(fs.existsSync(staging), false);
});

test('interrupted download removes the partial file and reports offline', async (t) => {
  const update = updateFor(NEXT_VERSION);
  const env = fullEnvironment(t, {
    routes: {
      [update.url]: () => {
        let sent = false;
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          body: {
            getReader: () => ({
              read: async () => {
                if (!sent) {
                  sent = true;
                  return { done: false, value: new Uint8Array([1, 2, 3]) };
                }
                throw new Error('socket hang up');
              },
              cancel: async () => {}
            })
          }
        };
      }
    }
  });
  const { updater } = makeSelfUpdater({
    bundle: env.bundle, fetch: env.fetchImpl, execFile: env.execFile, logsDir: env.logsDir
  });
  const result = await updater.start(update);
  assert.equal(result.ok, false);
  assert.match(result.reason, /zip-download-failed: socket hang up/);
  assert.equal(classifyFailure(result.reason), 'offline');
  const staging = path.join(env.bundle.parent, `.EasyLens-update-${NEXT_VERSION}`);
  assert.equal(fs.existsSync(staging), false);
});

test('a zip whose executable is the wrong arch is refused as arch mismatch', async (t) => {
  const update = armUpdateFor(NEXT_VERSION);
  const env = fullEnvironment(t, { update, fileOutput: 'Mach-O 64-bit executable x86_64\n' });
  const { updater } = makeSelfUpdater({
    bundle: env.bundle, fetch: env.fetchImpl, execFile: env.execFile, logsDir: env.logsDir
  }, { arch: 'arm64' });
  const result = await updater.start(update);
  assert.equal(result.ok, false);
  assert.match(result.reason, /^arch-mismatch/);
  assert.equal(classifyFailure(result.reason), 'arch');
});

function probeUpdater(t, { arch, update, outcome }) {
  const collector = makeCollector();
  const updater = setupAutoUpdate({
    app: makeProbeApp(),
    net: { fetch: async () => ({ status: 200, json: async () => update }) },
    selfUpdate: { available: true, start: async () => outcome },
    onStatus: collector.onStatus,
    logger: () => {},
    platform: 'darwin',
    arch,
    schedule: false
  });
  t.after(() => updater.stop());
  return { collector, updater };
}

test('sha256 failure ends in checksum state pointing at this machine\'s dmg (arm64)', async (t) => {
  const { collector, updater } = probeUpdater(t, {
    arch: 'arm64',
    update: armUpdateFor(NEXT_VERSION),
    outcome: { ok: false, reason: 'sha256-mismatch: expected a, got b', version: NEXT_VERSION }
  });
  updater.checkNow({ manual: true });
  await collector.waitFor('checksum');
  const last = collector.statuses.at(-1);
  assert.equal(last.url, `https://github.com/allen-bot-ctl/EasyLens/releases/download/v${NEXT_VERSION}/EasyLens-${NEXT_VERSION}-mac-arm64.dmg`);
});

test('arch mismatch ends in arch state pointing at the Release page', async (t) => {
  const { collector, updater } = probeUpdater(t, {
    arch: 'arm64',
    update: updateFor(NEXT_VERSION),
    outcome: { ok: false, reason: 'unsupported-arch', version: NEXT_VERSION }
  });
  updater.checkNow({ manual: false });
  await collector.waitFor('arch');
  assert.equal(collector.statuses.at(-1).url, `https://github.com/allen-bot-ctl/EasyLens/releases/tag/v${NEXT_VERSION}`);
});

test('interrupted download goes back to the plain check entry (error state)', async (t) => {
  const { collector, updater } = probeUpdater(t, {
    arch: 'x64',
    update: updateFor(NEXT_VERSION),
    outcome: { ok: false, reason: 'zip-download-failed: socket hang up', version: NEXT_VERSION }
  });
  updater.checkNow({ manual: true });
  await collector.waitFor('error');
  assert.deepEqual(collector.statuses.map((s) => s.state), ['checking', 'downloading', 'error']);
});
