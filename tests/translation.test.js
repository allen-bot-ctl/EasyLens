'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const { lookup, glossFor } = require('../electron/app/local-dictionary');
const localTranslator = require('../electron/app/local-translator');
const {
  endpointFor,
  translateWord,
  translateSelection
} = require('../electron/app/deepseek');
const {
  validatedBaseURL,
  createSettingsStore
} = require('../electron/app/settings-store');

test('local dictionary handles exact words and inflections', () => {
  assert.match(glossFor('hello').text, /喂|你好/);
  assert.equal(glossFor('services').matched, 'services');
  assert.equal(glossFor('rights').matched, 'rights');
  assert.equal(glossFor('meetings').matched, 'meeting');
  assert.equal(glossFor('happier').matched, 'happy');
  assert.ok(lookup('deepseek'));
  assert.equal(glossFor('zzzznotaword'), null);
});

test('local translator returns a word gloss and a selection fallback', () => {
  const word = localTranslator.translateWord('hello');
  assert.ok(word && word.chinese);
  assert.equal(word.basis, '本地词典');
  const selection = localTranslator.translateSelection('hello world');
  assert.ok(selection && selection.chinese.includes('世界'));
  assert.equal(selection.quality, 'fallback');
});

test('DeepSeek requests the configured endpoint and model', async () => {
  let captured;
  const fetchImpl = async (url, init) => {
    captured = { url: String(url), init, body: JSON.parse(init.body) };
    return {
      ok: true,
      status: 200,
      json: async () => ({ choices: [{ message: { content: '上海' } }] })
    };
  };
  const result = await translateWord({
    anchor: 'Shanghai',
    sentence: 'It is afternoon in Shanghai.',
    configuration: {
      baseURL: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      apiKey: 'test-key'
    },
    fetchImpl
  });
  assert.equal(result.chinese, '上海');
  assert.equal(captured.url, 'https://api.deepseek.com/chat/completions');
  assert.equal(captured.init.headers.Authorization, 'Bearer test-key');
  assert.equal(captured.body.model, 'deepseek-flash');
  assert.equal(captured.body.stream, false);
  assert.equal(captured.body.thinking.type, 'disabled');
  assert.match(captured.body.messages[1].content, /目标词：Shanghai/);
});

test('DeepSeek selection preserves paragraphs', async () => {
  const selected = 'First line.\nSecond line.';
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ choices: [{ message: { content: '第一行。\n第二行。' } }] })
  });
  const result = await translateSelection({
    text: selected,
    configuration: {
      baseURL: 'https://api.deepseek.com/v1',
      model: 'deepseek-v4-pro',
      apiKey: 'test-key'
    },
    fetchImpl
  });
  assert.equal(result, '第一行。\n第二行。');
  assert.equal(endpointFor('https://api.deepseek.com/v1').toString(),
    'https://api.deepseek.com/v1/chat/completions');
});

test('DeepSeek surfaces HTTP status errors', async () => {
  await assert.rejects(
    translateWord({
      anchor: 'hello',
      sentence: 'Hello!',
      configuration: {
        baseURL: 'https://api.deepseek.com',
        model: 'deepseek-flash',
        apiKey: 'bad'
      },
      fetchImpl: async () => ({ ok: false, status: 401 })
    }),
    /HTTP 401/
  );
});

test('base URL validation requires a clean HTTPS URL', () => {
  assert.equal(validatedBaseURL('http://api.deepseek.com'), null);
  assert.equal(validatedBaseURL('https://key@example.com'), null);
  assert.equal(validatedBaseURL('https://example.com/?q=1'), null);
  assert.ok(validatedBaseURL('https://api.deepseek.com/v1'));
});

test('API key is stored outside settings.json with restricted permissions', () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'easylens-settings-'));
  try {
    const store = createSettingsStore({ rootDir: scratch });
    store.load();
    assert.equal(store.getPublic().hasAPIKey, false);

    const saved = store.save({
      provider: 'deepSeek',
      baseURL: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      newAPIKey: '  sk-test-123  \n'
    });
    assert.equal(saved.hasAPIKey, true);
    assert.equal(saved.provider, 'deepSeek');
    assert.equal(store.deepSeekConfiguration().apiKey, 'sk-test-123');

    if (process.platform !== 'win32') {
      const dirMode = fs.statSync(scratch).mode & 0o777;
      const fileMode = fs.statSync(store.keyFile).mode & 0o777;
      assert.equal(dirMode, 0o700);
      assert.equal(fileMode, 0o600);
    }

    const persisted = fs.readFileSync(store.settingsFile, 'utf8');
    assert.equal(persisted.includes('sk-test-123'), false);

    const removed = store.removeAPIKey();
    assert.equal(removed.hasAPIKey, false);
    assert.equal(removed.provider, 'local');
    assert.equal(fs.existsSync(store.keyFile), false);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
});

test('settings reject non-HTTPS and missing keys', () => {
  const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'easylens-settings-'));
  try {
    const store = createSettingsStore({ rootDir: scratch });
    store.load();
    assert.throws(() => store.save({
      provider: 'local',
      baseURL: 'http://example.com',
      model: 'deepseek-flash',
      newAPIKey: ''
    }), /HTTPS/);
    assert.throws(() => store.save({
      provider: 'deepSeek',
      baseURL: 'https://api.deepseek.com',
      model: 'deepseek-flash',
      newAPIKey: ''
    }), /API Key/);
  } finally {
    fs.rmSync(scratch, { recursive: true, force: true });
  }
});
