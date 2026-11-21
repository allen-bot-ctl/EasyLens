'use strict';

// In-app self update for fully unsigned macOS builds.
//
// Squirrel.Mac refuses to work without a code signature, so the updater falls
// back to probing the public update feed and then hands the release zip to this
// module. Everything here is deliberately injectable (fetch/execFile/spawn/fs/
// path/logger) so tests never touch the network or a real /Applications bundle.
//
// The update is downloaded from the GitHub release URL, verified against the
// published .sha256 asset, extracted with ditto, checked against its
// CFBundleShortVersionString, and installed by a small /bin/sh script after the
// current process exits. If anything looks wrong we fall back to a manual DMG
// download instead of replacing the app.

const crypto = require('node:crypto');
const nodeFs = require('node:fs');
const nodePath = require('node:path');
const {
  execFile: defaultExecFile,
  spawn: defaultSpawn
} = require('node:child_process');
const { GITHUB_OWNER, GITHUB_REPO } = require('./update-feed');

const MAX_DOWNLOAD_BYTES = 500 * 1024 * 1024;
const STAGING_PREFIX = '.EasyLens-update-';
const BACKUP_PREFIX = '.EasyLens-backup-';
const VERIFIED_FILE = 'verified.json';
const INSTALL_SCRIPT_NAME = 'update-install.sh';
const INSTALL_LOG_NAME = 'update-install.log';
const APP_NAME = 'EasyLens.app';
// 0.1.9：EasyLens 同时发 x64 和 arm64，按 process.arch 选对应的 zip。
const SUPPORTED_ARCHES = Object.freeze(['x64', 'arm64']);
// `file -b` 输出里的架构名，用来核对解压出来的 .app 是不是本机芯片。
const MACHO_ARCH_NAMES = Object.freeze({ x64: 'x86_64', arm64: 'arm64' });

const SEMVER_RE = /^(\d+)\.(\d+)\.(\d+)$/;
const UPDATE_FILE_RE = /^EasyLens-(\d+\.\d+\.\d+)-mac-(x64|arm64)\.zip$/;
const UPDATE_TAG_RE = /^v(\d+\.\d+\.\d+)$/;

// Static installer script. Every path is a positional argument; no path ever
// gets interpolated into the script text. This keeps shell metacharacters in a
// bundle path or a version string from changing the meaning of the script.
const INSTALL_SCRIPT = `#!/bin/sh

PID="$1"
BUNDLE="$2"
NEW_APP="$3"
BACKUP="$4"
STAGING="$5"

say() {
  printf '%s %s\\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
}

say "update-install: waiting for pid $PID to exit"
waited=0
while kill -0 "$PID" 2>/dev/null; do
  if [ "$waited" -ge 60 ]; then
    say "update-install: timed out waiting for pid $PID; leaving current app unchanged"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

say "update-install: moving current app to backup"
if ! mv "$BUNDLE" "$BACKUP"; then
  say "update-install: failed to move current app to backup; reopening old app"
  /usr/bin/open -n "$BUNDLE"
  exit 1
fi

say "update-install: moving new app into place"
if ! mv "$NEW_APP" "$BUNDLE"; then
  say "update-install: failed to move new app into place; restoring backup"
  if mv "$BACKUP" "$BUNDLE"; then
    say "update-install: backup restored; reopening old app"
    /usr/bin/open -n "$BUNDLE"
  else
    say "update-install: failed to restore backup"
  fi
  exit 1
fi

say "update-install: new app installed; clearing quarantine"
/usr/bin/xattr -cr "$BUNDLE" 2>/dev/null || true

say "update-install: removing backup and staging"
rm -rf "$BACKUP"
rm -rf "$STAGING"

say "update-install: opening new app"
/usr/bin/open -n "$BUNDLE"
exit 0
`;

function parseSemver(value) {
  if (typeof value !== 'string') return null;
  const match = SEMVER_RE.exec(value.trim());
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3])
  };
}

function compareSemver(left, right) {
  const a = parseSemver(left);
  const b = parseSemver(right);
  if (!a || !b) return null;
  if (a.major !== b.major) return a.major < b.major ? -1 : 1;
  if (a.minor !== b.minor) return a.minor < b.minor ? -1 : 1;
  if (a.patch !== b.patch) return a.patch < b.patch ? -1 : 1;
  return 0;
}

function extractVersion(value) {
  if (typeof value !== 'string') return null;
  const match = /(\d+\.\d+\.\d+)/.exec(value);
  if (!match || !SEMVER_RE.test(match[1])) return null;
  return match[1];
}

function normalizeArch(arch) {
  const value = arch || process.arch;
  return SUPPORTED_ARCHES.includes(value) ? value : null;
}

// 本机芯片对应的 dmg；芯片不在支持列表里时返回 null，调用方回退到 Release 页。
function deriveDmgUrl(version, arch) {
  const normalized = typeof version === 'string'
    ? version.trim().replace(/^[vV]/, '')
    : '';
  if (!parseSemver(normalized)) return null;
  const dmgArch = normalizeArch(arch);
  if (!dmgArch) return null;
  return `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v${normalized}/EasyLens-${normalized}-mac-${dmgArch}.dmg`;
}

function deriveReleasePageUrl(version) {
  const normalized = typeof version === 'string'
    ? version.trim().replace(/^[vV]/, '')
    : '';
  if (!parseSemver(normalized)) {
    return `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/latest`;
  }
  return `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/tag/v${normalized}`;
}

// 把自更新失败的原因归到契约状态表里的一类：
// - arch：Release 里没有本机芯片的 zip，或 zip 里的架构不对 → 打开 Release 页
// - checksum：sha256 不一致 → 打开本机芯片对应的 dmg
// - offline：下载中断 / 网络失败 → 半截文件已删，下一次定时检查再试
// - manual：其他（不在「应用程序」目录、被隔离运行、解压失败等）→ 打开 dmg
function classifyFailure(reason) {
  const text = typeof reason === 'string' ? reason : '';
  if (text === 'unsupported-arch' || text.startsWith('arch-mismatch')) return 'arch';
  if (text.startsWith('sha256-mismatch') || text === 'sha256-missing-or-invalid') {
    return 'checksum';
  }
  if (text.startsWith('zip-download-failed') ||
      text.startsWith('sha256-download-failed') ||
      text.startsWith('sha256-read-failed') ||
      /^(zip|sha256)-download-status-5\d\d$/.test(text)) {
    return 'offline';
  }
  return 'manual';
}

// Validates the feed URL supplied by update.electronjs.org. The feed for this
// repo points directly at a GitHub release asset; anything outside the exact
// expected owner/repo/tag/filename shape is refused before any download.
function parseUpdateUrl(update, options = {}) {
  const urlText = typeof update === 'string'
    ? update.trim()
    : update && typeof update.url === 'string'
      ? update.url.trim()
      : '';
  const name = typeof update === 'object' && update && typeof update.name === 'string'
    ? update.name.trim()
    : '';

  if (!urlText) return { ok: false, reason: 'missing-url' };

  let parsed;
  try {
    parsed = new URL(urlText);
  } catch {
    return { ok: false, reason: 'invalid-url' };
  }

  if (parsed.protocol !== 'https:') {
    return { ok: false, reason: 'invalid-scheme' };
  }
  if (parsed.hostname !== 'github.com' || parsed.port !== '') {
    return { ok: false, reason: 'invalid-host' };
  }
  if (parsed.username || parsed.password) {
    return { ok: false, reason: 'invalid-credentials' };
  }
  if (parsed.search || parsed.hash) {
    return { ok: false, reason: 'invalid-url-suffix' };
  }

  const segments = parsed.pathname.split('/').filter(Boolean).map((part) => {
    try {
      return decodeURIComponent(part);
    } catch {
      return part;
    }
  });

  if (segments.length !== 6 ||
      segments[0] !== GITHUB_OWNER ||
      segments[1] !== GITHUB_REPO ||
      segments[2] !== 'releases' ||
      segments[3] !== 'download') {
    return { ok: false, reason: 'unexpected-path' };
  }

  const tagMatch = UPDATE_TAG_RE.exec(segments[4]);
  const fileMatch = UPDATE_FILE_RE.exec(segments[5]);
  const parsedVersion = tagMatch ? tagMatch[1] : null;
  const fileVersion = fileMatch ? fileMatch[1] : null;
  const version = parsedVersion || fileVersion || extractVersion(segments[5]);

  if (!tagMatch || !fileMatch) {
    return { ok: false, reason: 'unexpected-asset-name', version };
  }
  if (parsedVersion !== fileVersion) {
    return { ok: false, reason: 'version-mismatch', version };
  }

  const arch = options.arch || process.arch;
  const fileArch = fileMatch[2];
  if (!SUPPORTED_ARCHES.includes(arch) || fileArch !== arch) {
    // 更新源给的 zip 不是本机芯片的（例如 Release 里缺 arm64 包时退回 x64），
    // 不去猜，回退到 Release 页让用户自己选。
    return { ok: false, reason: 'unsupported-arch', version };
  }

  const appVersion = options.appVersion;
  const comparison = compareSemver(version, appVersion);
  if (comparison === null) {
    return { ok: false, reason: 'invalid-version', version };
  }
  if (comparison <= 0) {
    return { ok: false, reason: 'not-newer', version };
  }

  return {
    ok: true,
    version,
    filename: segments[5],
    arch: fileArch,
    name: name || `EasyLens v${version}`,
    url: `https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}/releases/download/v${version}/${segments[5]}`,
    dmgUrl: deriveDmgUrl(version, fileArch)
  };
}

function resolveBundlePath(options = {}) {
  const fsImpl = options.fs || nodeFs;
  const pathImpl = options.path || nodePath;
  const execPath = options.execPath;

  let bundlePath;
  if (typeof options.bundlePath === 'string' && options.bundlePath.trim() !== '') {
    bundlePath = options.bundlePath;
  } else {
    if (typeof execPath !== 'string' || execPath.trim() === '') {
      return { ok: false, reason: 'missing-exec-path' };
    }
    bundlePath = pathImpl.dirname(
      pathImpl.dirname(pathImpl.dirname(execPath))
    );
  }

  if (!bundlePath || bundlePath === pathImpl.dirname(bundlePath)) {
    return { ok: false, reason: 'invalid-bundle-path' };
  }
  if (pathImpl.basename(bundlePath).slice(-4) !== '.app') {
    return { ok: false, reason: 'not-an-app-bundle' };
  }
  if (String(execPath || '').includes('/AppTranslocation/') ||
      bundlePath.includes('/AppTranslocation/')) {
    return { ok: false, reason: 'translocated' };
  }

  const parent = typeof options.parent === 'string' && options.parent.trim() !== ''
    ? options.parent
    : pathImpl.dirname(bundlePath);
  const writeFlag = fsImpl.constants && Number.isInteger(fsImpl.constants.W_OK)
    ? fsImpl.constants.W_OK
    : nodeFs.constants.W_OK;

  try {
    fsImpl.accessSync(parent, writeFlag);
    fsImpl.accessSync(bundlePath, writeFlag);
  } catch {
    return { ok: false, reason: 'not-writable' };
  }

  return { ok: true, bundlePath, parent };
}

// Parses the release's .sha256 asset. The format is a single hex digest,
// optionally followed by whitespace and the zip filename (shasum output). A
// filename, when present, must name exactly the zip we downloaded.
function parseSha256File(text, expectedFilename) {
  if (typeof text !== 'string') return null;
  const line = text.split(/\r?\n/).map((part) => part.trim()).find(Boolean);
  if (!line) return null;

  const match = /^([0-9a-fA-F]{64})(?:\s+\*?(\S+))?\s*$/.exec(line);
  if (!match) return null;

  const filename = match[2] || '';
  if (filename && expectedFilename && filename !== expectedFilename) {
    return null;
  }
  return match[1].toLowerCase();
}

function responseOk(response) {
  if (!response) return false;
  if (typeof response.ok === 'boolean') return response.ok;
  return Number(response.status) >= 200 && Number(response.status) < 300;
}

function runExec(execFileImpl, file, args, options) {
  return new Promise((resolve, reject) => {
    let settled = false;
    const finish = (error, stdout, stderr) => {
      if (settled) return;
      settled = true;
      if (error) reject(error);
      else resolve({ stdout: stdout || '', stderr: stderr || '' });
    };

    let result;
    try {
      result = execFileImpl(file, args, options || {}, finish);
    } catch (error) {
      finish(error);
      return;
    }

    if (result && typeof result.then === 'function') {
      result.then(
        (value) => finish(null, value && value.stdout, value && value.stderr),
        (error) => finish(error)
      );
    }
  });
}

function findSingleApp(directory, fsImpl, pathImpl) {
  let entries;
  try {
    entries = fsImpl.readdirSync(directory, { withFileTypes: true });
  } catch {
    return null;
  }

  const apps = [];
  for (const entry of entries) {
    const name = typeof entry === 'string' ? entry : entry && entry.name;
    if (typeof name !== 'string' || !name.endsWith('.app')) continue;

    let isDirectory = true;
    if (entry && typeof entry.isDirectory === 'function') {
      isDirectory = entry.isDirectory();
    } else {
      try {
        isDirectory = fsImpl.statSync(pathImpl.join(directory, name)).isDirectory();
      } catch {
        isDirectory = false;
      }
    }
    if (isDirectory) apps.push(name);
  }

  if (apps.length !== 1) return null;
  return pathImpl.join(directory, apps[0]);
}

function readVerifiedMarker(staging, version, fsImpl, pathImpl) {
  try {
    const raw = fsImpl.readFileSync(pathImpl.join(staging, VERIFIED_FILE), 'utf8');
    const marker = JSON.parse(raw);
    return Boolean(marker && marker.version === version);
  } catch {
    return false;
  }
}

function writeVerifiedMarker(staging, version, fsImpl, pathImpl) {
  const marker = {
    version,
    verifiedAt: new Date().toISOString(),
    app: APP_NAME
  };
  fsImpl.writeFileSync(
    pathImpl.join(staging, VERIFIED_FILE),
    JSON.stringify(marker) + '\n',
    'utf8'
  );
}

async function verifyStagedApp(context) {
  const {
    newApp,
    version,
    execFile,
    fsImpl,
    pathImpl,
    log
  } = context;

  const contents = pathImpl.join(newApp, 'Contents');
  const infoPlist = pathImpl.join(contents, 'Info.plist');

  let stdout;
  try {
    ({ stdout } = await runExec(
      execFile,
      '/usr/bin/plutil',
      ['-extract', 'CFBundleShortVersionString', 'raw', '-o', '-', infoPlist],
      { encoding: 'utf8' }
    ));
  } catch (error) {
    return { ok: false, reason: `plist-version-unreadable: ${error.message || error}` };
  }

  const plistVersion = String(stdout || '').trim();
  if (plistVersion !== version) {
    return {
      ok: false,
      reason: `plist-version-mismatch: expected ${version}, got ${plistVersion || '(empty)'}`
    };
  }

  let executable;
  try {
    ({ stdout: executable } = await runExec(
      execFile,
      '/usr/bin/plutil',
      ['-extract', 'CFBundleExecutable', 'raw', '-o', '-', infoPlist],
      { encoding: 'utf8' }
    ));
  } catch (error) {
    return { ok: false, reason: `plist-executable-unreadable: ${error.message || error}` };
  }

  const executableName = String(executable || '').trim();
  if (!executableName ||
      executableName.includes('/') ||
      executableName.includes('\\') ||
      executableName === '.' ||
      executableName === '..') {
    return { ok: false, reason: 'invalid-bundle-executable' };
  }

  const executablePath = pathImpl.join(contents, 'MacOS', executableName);
  let exists = false;
  try {
    exists = typeof fsImpl.existsSync === 'function'
      ? fsImpl.existsSync(executablePath)
      : false;
  } catch {
    exists = false;
  }
  if (!exists) {
    return { ok: false, reason: `bundle-executable-missing: ${executableName}` };
  }

  // 0.1.9：核对 zip 里的可执行文件是不是本机芯片。`file` 是系统自带命令，
  // 不依赖 Xcode 命令行工具；读不出来时只记日志，不拦更新。
  const expectedArch = context.arch && MACHO_ARCH_NAMES[context.arch];
  if (expectedArch) {
    try {
      const { stdout: described } = await runExec(
        execFile,
        '/usr/bin/file',
        ['-b', executablePath],
        { encoding: 'utf8' }
      );
      const text = String(described || '');
      if (/Mach-O/.test(text) && !text.includes(expectedArch)) {
        return { ok: false, reason: `arch-mismatch: expected ${expectedArch}, got ${text.trim()}` };
      }
    } catch (error) {
      log(`arch check skipped: ${error.message || error}`);
    }
  }

  log(`verified staged app ${newApp} as v${version}`);
  return { ok: true };
}

function cleanupStaleStaging(parent, keepPath, fsImpl, pathImpl, log) {
  let names;
  try {
    names = fsImpl.readdirSync(parent);
  } catch {
    return;
  }

  for (const name of names) {
    if (typeof name !== 'string' || !name.startsWith(STAGING_PREFIX)) continue;
    const fullPath = pathImpl.join(parent, name);
    if (pathImpl.resolve(fullPath) === pathImpl.resolve(keepPath)) continue;
    try {
      fsImpl.rmSync(fullPath, { recursive: true, force: true });
      log(`removed stale staging directory ${fullPath}`);
    } catch {
      // Best effort only; a locked stale directory must not block an update.
    }
  }
}

async function streamResponseToFile(context) {
  const {
    response,
    destination,
    fsImpl,
    maxBytes
  } = context;

  const hash = crypto.createHash('sha256');
  let total = 0;

  const contentLength = response.headers &&
    typeof response.headers.get === 'function'
    ? Number(response.headers.get('content-length'))
    : NaN;
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new Error(`download-too-large: ${contentLength} bytes`);
  }

  const canStream = response.body &&
    typeof response.body.getReader === 'function' &&
    typeof fsImpl.createWriteStream === 'function';

  if (!canStream) {
    const buffer = typeof response.arrayBuffer === 'function'
      ? Buffer.from(await response.arrayBuffer())
      : Buffer.alloc(0);
    if (buffer.length === 0) throw new Error('empty-download');
    if (buffer.length > maxBytes) {
      throw new Error(`download-too-large: ${buffer.length} bytes`);
    }
    hash.update(buffer);
    fsImpl.writeFileSync(destination, buffer);
    return { sha256: hash.digest('hex'), bytes: buffer.length };
  }

  const output = fsImpl.createWriteStream(destination);
  // 先挂上 error 监听：下载中断后流可能晚一步报错（例如目录已被清掉），
  // 不能让它变成未捕获异常。
  output.on('error', () => {});
  const reader = response.body.getReader();

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      const chunk = Buffer.from(value);
      total += chunk.length;
      if (total > maxBytes) {
        try {
          await reader.cancel();
        } catch {
          // Ignore cancellation failures; the size check still aborts.
        }
        throw new Error(`download-too-large: more than ${maxBytes} bytes`);
      }
      hash.update(chunk);
      if (!output.write(chunk)) {
        await new Promise((resolve, reject) => {
          output.once('drain', resolve);
          output.once('error', reject);
        });
      }
    }

    await new Promise((resolve, reject) => {
      output.end(resolve);
      output.once('error', reject);
    });
  } catch (error) {
    try {
      output.destroy();
      if (output.closed === false) {
        await new Promise((resolve) => {
          output.once('close', resolve);
        });
      }
    } catch {
      // Already closed.
    }
    try {
      fsImpl.unlinkSync(destination);
    } catch {
      // Nothing to clean up.
    }
    throw error;
  }

  if (total === 0) throw new Error('empty-download');
  return { sha256: hash.digest('hex'), bytes: total };
}

async function downloadAndVerify(context) {
  const {
    fetchImpl,
    url,
    filename,
    staging,
    fsImpl,
    pathImpl,
    log,
    maxBytes
  } = context;

  let zipResponse;
  try {
    zipResponse = await fetchImpl(url, {
      redirect: 'follow',
      cache: 'no-store'
    });
  } catch (error) {
    return { ok: false, reason: `zip-download-failed: ${error.message || error}` };
  }
  if (!responseOk(zipResponse)) {
    return { ok: false, reason: `zip-download-status-${zipResponse && zipResponse.status}` };
  }

  const zipPath = pathImpl.join(staging, filename);
  let download;
  try {
    download = await streamResponseToFile({
      response: zipResponse,
      destination: zipPath,
      fsImpl,
      maxBytes
    });
  } catch (error) {
    return { ok: false, reason: `zip-download-failed: ${error.message || error}` };
  }
  log(`downloaded ${filename} (${download.bytes} bytes, sha256 ${download.sha256})`);

  let shaResponse;
  try {
    shaResponse = await fetchImpl(`${url}.sha256`, {
      redirect: 'follow',
      cache: 'no-store'
    });
  } catch (error) {
    return { ok: false, reason: `sha256-download-failed: ${error.message || error}` };
  }
  if (!responseOk(shaResponse)) {
    return { ok: false, reason: `sha256-download-status-${shaResponse && shaResponse.status}` };
  }

  let shaText = '';
  try {
    shaText = typeof shaResponse.text === 'function'
      ? await shaResponse.text()
      : '';
  } catch (error) {
    return { ok: false, reason: `sha256-read-failed: ${error.message || error}` };
  }

  const expected = parseSha256File(shaText, filename);
  if (!expected) {
    return { ok: false, reason: 'sha256-missing-or-invalid' };
  }
  if (download.sha256.toLowerCase() !== expected) {
    return {
      ok: false,
      reason: `sha256-mismatch: expected ${expected}, got ${download.sha256}`
    };
  }

  return { ok: true, zipPath, sha256: download.sha256 };
}

async function prepareStaging(context) {
  const {
    bundle,
    version,
    fetchImpl,
    execFile,
    fsImpl,
    pathImpl,
    log,
    maxBytes
  } = context;

  const staging = pathImpl.join(bundle.parent, `${STAGING_PREFIX}${version}`);
  cleanupStaleStaging(bundle.parent, staging, fsImpl, pathImpl, log);

  const existingApp = pathImpl.join(staging, APP_NAME);
  if (readVerifiedMarker(staging, version, fsImpl, pathImpl)) {
    const candidate = findSingleApp(staging, fsImpl, pathImpl);
    if (candidate) {
      const verified = await verifyStagedApp({
        newApp: candidate,
        version,
        arch: context.arch,
        execFile,
        fsImpl,
        pathImpl,
        log
      });
      if (verified.ok) {
        log(`reusing verified staged update at ${candidate}`);
        return { ok: true, staging, newApp: candidate, reused: true };
      }
      log(`staged update failed re-verification: ${verified.reason}`);
    } else {
      log(`verified marker present but staged app is missing: ${existingApp}`);
    }
  }

  try {
    fsImpl.rmSync(staging, { recursive: true, force: true });
    fsImpl.mkdirSync(staging, { recursive: true });
  } catch (error) {
    return { ok: false, reason: `staging-create-failed: ${error.message || error}` };
  }

  const filename = context.filename;
  const downloaded = await downloadAndVerify({
    fetchImpl,
    url: context.url,
    filename,
    staging,
    fsImpl,
    pathImpl,
    log,
    maxBytes
  });
  if (!downloaded.ok) {
    // 契约：sha256 校验失败要删掉已下载的 zip；下载中断要删掉半截文件。
    try {
      fsImpl.rmSync(staging, { recursive: true, force: true });
      log(`removed staging after failed download: ${downloaded.reason}`);
    } catch (error) {
      log(`staging cleanup failed: ${error.message || error}`);
    }
    return downloaded;
  }

  log(`extracting ${filename} into ${staging}`);
  try {
    await runExec(
      execFile,
      '/usr/bin/ditto',
      ['-x', '-k', downloaded.zipPath, staging],
      {}
    );
  } catch (error) {
    return { ok: false, reason: `extract-failed: ${error.message || error}` };
  }

  const newApp = findSingleApp(staging, fsImpl, pathImpl);
  if (!newApp) {
    return { ok: false, reason: 'extract-expected-one-app' };
  }

  const verified = await verifyStagedApp({
    newApp,
    version,
    arch: context.arch,
    execFile,
    fsImpl,
    pathImpl,
    log
  });
  if (!verified.ok) {
    try {
      fsImpl.rmSync(staging, { recursive: true, force: true });
    } catch {
      // Best effort.
    }
    return verified;
  }

  try {
    await runExec(execFile, '/usr/bin/xattr', ['-cr', newApp], {});
    log(`cleared quarantine attributes on ${newApp}`);
  } catch (error) {
    log(`xattr failed (ignored): ${error.message || error}`);
  }

  try {
    writeVerifiedMarker(staging, version, fsImpl, pathImpl);
  } catch (error) {
    return { ok: false, reason: `marker-write-failed: ${error.message || error}` };
  }

  try {
    fsImpl.unlinkSync(downloaded.zipPath);
  } catch {
    // The extracted bundle is already verified; a leftover zip is harmless.
  }

  return { ok: true, staging, newApp, reused: false };
}

function createMacSelfUpdater(options = {}) {
  const platform = options.platform || process.platform;
  const arch = options.arch || process.arch;
  const fsImpl = options.fs || nodeFs;
  const pathImpl = options.path ||
    (options.paths && typeof options.paths.join === 'function'
      ? options.paths
      : nodePath);
  const fetchImpl = options.fetch;
  const execFileImpl = options.execFile || defaultExecFile;
  const spawnImpl = options.spawn || defaultSpawn;
  const appVersion = options.appVersion;
  const maxBytes = Number.isFinite(options.maxDownloadBytes) &&
    options.maxDownloadBytes > 0
    ? options.maxDownloadBytes
    : MAX_DOWNLOAD_BYTES;
  const log = typeof options.logger === 'function'
    ? options.logger
    : () => {};

  const available = platform === 'darwin' &&
    options.isPackaged === true &&
    SUPPORTED_ARCHES.includes(arch) &&
    typeof fetchImpl === 'function';

  let currentJob = null;
  let lastReady = null;

  function resetJob() {
    currentJob = null;
  }

  async function runJob(update) {
    const parsed = parseUpdateUrl(update, { arch, appVersion });
    if (!parsed.ok) {
      log(`refusing self-update: ${parsed.reason}`);
      return {
        ok: false,
        reason: parsed.reason,
        version: parsed.version || extractVersion(update && update.name) ||
          extractVersion(update && update.url)
      };
    }

    const bundle = resolveBundlePath({
      execPath: options.execPath ||
        (options.paths && options.paths.execPath) ||
        process.execPath,
      bundlePath: options.bundlePath ||
        (options.paths && options.paths.bundlePath),
      parent: options.parent ||
        (options.paths && options.paths.parent),
      fs: fsImpl,
      path: pathImpl
    });
    if (!bundle.ok) {
      log(`refusing self-update: ${bundle.reason}`);
      return { ok: false, reason: bundle.reason, version: parsed.version };
    }

    log(`starting self-update to v${parsed.version} in ${bundle.parent}`);
    const prepared = await prepareStaging({
      bundle,
      version: parsed.version,
      arch,
      filename: parsed.filename,
      url: parsed.url,
      fetchImpl,
      execFile: execFileImpl,
      fsImpl,
      pathImpl,
      log,
      maxBytes
    });

    if (!prepared.ok) {
      log(`self-update staging failed: ${prepared.reason}`);
      return { ok: false, reason: prepared.reason, version: parsed.version };
    }

    return {
      ok: true,
      mode: 'ready-self',
      version: parsed.version,
      name: parsed.name,
      newApp: prepared.newApp,
      staging: prepared.staging,
      bundlePath: bundle.bundlePath,
      parent: bundle.parent,
      reused: prepared.reused
    };
  }

  function start(update) {
    if (!available) {
      const version = extractVersion(update && update.name) ||
        extractVersion(update && update.url);
      return Promise.resolve({
        ok: false,
        reason: 'self-update-unavailable',
        version
      });
    }

    if (currentJob) {
      log('self-update job already in flight; joining it');
      return currentJob;
    }

    currentJob = runJob(update).then(
      (result) => {
        resetJob();
        if (result && result.ok) lastReady = result;
        return result;
      },
      (error) => {
        resetJob();
        const reason = `self-update-failed: ${error && error.message ? error.message : error}`;
        log(reason);
        return {
          ok: false,
          reason,
          version: extractVersion(update && update.name) ||
            extractVersion(update && update.url)
        };
      }
    );
    return currentJob;
  }

  function resolveLogsDir() {
    let dir;
    try {
      dir = typeof options.getLogsPath === 'function'
        ? options.getLogsPath()
        : options.logsDir ||
          (options.paths && (options.paths.logsDir || options.paths.logs));
    } catch {
      return null;
    }
    return typeof dir === 'string' && dir.trim() ? dir : null;
  }

  function installReady() {
    if (!lastReady) {
      return { ok: false, reason: 'no-ready-self-update' };
    }

    const ready = lastReady;
    if (!fsImpl.existsSync(ready.newApp)) {
      return { ok: false, reason: 'staged-app-missing' };
    }

    const logsDir = resolveLogsDir();
    if (!logsDir) {
      return { ok: false, reason: 'logs-directory-unavailable' };
    }

    const scriptPath = pathImpl.join(ready.staging, INSTALL_SCRIPT_NAME);
    try {
      fsImpl.writeFileSync(scriptPath, INSTALL_SCRIPT, {
        encoding: 'utf8',
        mode: 0o700
      });
      fsImpl.mkdirSync(logsDir, { recursive: true });
    } catch (error) {
      return { ok: false, reason: `install-script-failed: ${error.message || error}` };
    }

    const installLog = pathImpl.join(logsDir, INSTALL_LOG_NAME);
    const backupPath = pathImpl.join(
      ready.parent,
      `${BACKUP_PREFIX}${ready.version}.app`
    );
    const pid = options.pid || process.pid;

    // A previous interrupted attempt may have left a backup behind. mv would
    // otherwise move the current bundle *inside* that directory on macOS.
    try {
      fsImpl.rmSync(backupPath, { recursive: true, force: true });
    } catch {
      // Best effort; the script reports a failed backup move if it remains.
    }

    log(`writing install script ${scriptPath}`);
    log(`installer will replace ${ready.bundlePath} with ${ready.newApp} (backup ${backupPath})`);

    let fd = null;
    try {
      fd = fsImpl.openSync(installLog, 'a');
      const child = spawnImpl(
        '/bin/sh',
        [
          scriptPath,
          String(pid),
          ready.bundlePath,
          ready.newApp,
          backupPath,
          ready.staging
        ],
        {
          detached: true,
          stdio: ['ignore', fd, fd]
        }
      );
      if (child && typeof child.unref === 'function') child.unref();
    } catch (error) {
      return { ok: false, reason: `install-spawn-failed: ${error.message || error}` };
    } finally {
      if (fd !== null) {
        try {
          fsImpl.closeSync(fd);
        } catch {
          // The child holds its own descriptor; closing the parent copy may fail.
        }
      }
    }

    log(`installer started for v${ready.version}; install log ${installLog}`);
    lastReady = null;

    if (typeof options.quit === 'function') {
      try {
        options.quit();
      } catch (error) {
        log(`quit callback failed: ${error.message || error}`);
      }
    }

    return { ok: true, scriptPath, installLog, backupPath };
  }

  return {
    available,
    start,
    installReady,
    get lastReady() {
      return lastReady;
    }
  };
}

module.exports = {
  MAX_DOWNLOAD_BYTES,
  STAGING_PREFIX,
  BACKUP_PREFIX,
  VERIFIED_FILE,
  INSTALL_SCRIPT_NAME,
  INSTALL_LOG_NAME,
  INSTALL_SCRIPT,
  compareSemver,
  extractVersion,
  SUPPORTED_ARCHES,
  deriveDmgUrl,
  deriveReleasePageUrl,
  classifyFailure,
  parseUpdateUrl,
  resolveBundlePath,
  parseSha256File,
  parseSha256: parseSha256File,
  buildInstallScript: () => INSTALL_SCRIPT,
  createMacSelfUpdater
};
