'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  buildFeedUrl,
  interpretFeedProbe,
  GITHUB_OWNER,
  GITHUB_REPO,
  UPDATE_SERVER
} = require('../electron/update-feed');

test('feed URL uses the official service, repository, platform, arch and version', () => {
  assert.equal(GITHUB_OWNER, 'allen-bot-ctl');
  assert.equal(GITHUB_REPO, 'EasyLens');
  assert.equal(UPDATE_SERVER, 'https://update.electronjs.org');

  assert.equal(
    buildFeedUrl({
      platform: 'darwin',
      arch: 'x64',
      version: '0.1.1'
    }),
    'https://update.electronjs.org/allen-bot-ctl/EasyLens/darwin-x64/0.1.1'
  );
});

test('feed URL accepts an explicit owner, repo, server and trims trailing slashes', () => {
  assert.equal(
    buildFeedUrl({
      owner: 'example',
      repo: 'demo',
      server: 'https://updates.example.com/',
      platform: 'darwin',
      arch: 'arm64',
      version: '2.3.4'
    }),
    'https://updates.example.com/example/demo/darwin-arm64/2.3.4'
  );
});

test('feed URL rejects missing platform, arch or version', () => {
  assert.throws(
    () => buildFeedUrl({ platform: 'darwin', arch: 'x64' }),
    /version is required/
  );
  assert.throws(
    () => buildFeedUrl({ platform: 'darwin', version: '0.1.1' }),
    /arch is required/
  );
  assert.throws(
    () => buildFeedUrl({ arch: 'x64', version: '0.1.1' }),
    /platform is required/
  );
});

test('feed probe maps 204 to up-to-date', () => {
  assert.deepEqual(interpretFeedProbe(204, null), { state: 'up-to-date' });
});

test('feed probe maps 200 with a valid update payload to manual download and keeps the asset url', () => {
  const assetUrl = 'https://github.com/allen-bot-ctl/EasyLens/releases/download/v0.1.3/EasyLens-0.1.3-mac-x64.zip';
  assert.deepEqual(
    interpretFeedProbe(200, { name: 'v0.1.3', url: assetUrl }),
    { state: 'manual', name: 'v0.1.3', url: assetUrl }
  );
  assert.deepEqual(
    interpretFeedProbe(200, { name: 'v0.1.3' }),
    { state: 'manual', name: 'v0.1.3' }
  );
  assert.deepEqual(
    interpretFeedProbe(200, { url: assetUrl }),
    { state: 'manual', name: 'latest', url: assetUrl }
  );
});

test('feed probe treats network/parse failures and 4xx/5xx (except 204) as errors', () => {
  assert.deepEqual(interpretFeedProbe(200, null), { state: 'error' });
  assert.deepEqual(interpretFeedProbe(200, {}), { state: 'error' });
  assert.deepEqual(interpretFeedProbe(404, null), { state: 'error' });
  assert.deepEqual(interpretFeedProbe(500, null), { state: 'error' });
  assert.deepEqual(interpretFeedProbe(0, null), { state: 'error' });
});
