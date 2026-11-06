'use strict';

const form = document.getElementById('form');
const provider = document.getElementById('provider');
const baseURL = document.getElementById('baseURL');
const model = document.getElementById('model');
const apiKey = document.getElementById('apiKey');
const keyStatus = document.getElementById('keyStatus');
const removeKey = document.getElementById('removeKey');
const testButton = document.getElementById('test');
const closeButton = document.getElementById('close');
const saveButton = document.getElementById('save');
const message = document.getElementById('message');

let current = null;
let testing = false;

function setMessage(value, kind = '') {
  message.textContent = value || '';
  message.className = `message${kind ? ` ${kind}` : ''}`;
}

function applySettings(settings) {
  current = settings;
  provider.value = settings.provider;
  baseURL.value = settings.baseURL;
  model.value = settings.model;
  apiKey.value = '';
  apiKey.placeholder = settings.hasAPIKey
    ? '已保存；留空则保持原密钥'
    : '输入 DeepSeek API Key';
  keyStatus.textContent = settings.hasAPIKey
    ? '密钥已保存在 ~/.easylens'
    : '尚未保存密钥';
  removeKey.hidden = !settings.hasAPIKey;
  testButton.disabled = !settings.hasAPIKey || testing;
}

function setTesting(value) {
  testing = value;
  testButton.textContent = value ? '正在测试…' : '测试连接';
  testButton.disabled = value || !current?.hasAPIKey;
  saveButton.disabled = value;
}

async function refresh() {
  try {
    const settings = await window.easylens.settings.get();
    applySettings(settings);
  } catch (error) {
    setMessage(`读取设置失败：${error.message}`, 'error');
  }
}

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  setMessage('正在保存…');
  saveButton.disabled = true;
  try {
    const result = await window.easylens.settings.save({
      provider: provider.value,
      baseURL: baseURL.value,
      model: model.value.trim(),
      newAPIKey: apiKey.value
    });
    if (!result.ok) {
      setMessage(result.error || '保存失败。', 'error');
      return;
    }
    applySettings(result.settings);
    setMessage('设置已保存。', 'success');
  } catch (error) {
    setMessage(`保存失败：${error.message}`, 'error');
  } finally {
    saveButton.disabled = false;
    setTesting(false);
  }
});

testButton.addEventListener('click', async () => {
  setTesting(true);
  setMessage('正在请求 DeepSeek…');
  try {
    const result = await window.easylens.settings.test();
    if (!result.ok) {
      setMessage(result.error || '连接失败。', 'error');
    } else {
      setMessage(`连接成功，示例译文：${result.text}`, 'success');
    }
  } catch (error) {
    setMessage(`连接失败：${error.message}`, 'error');
  } finally {
    setTesting(false);
  }
});

removeKey.addEventListener('click', async () => {
  setMessage('正在移除密钥…');
  try {
    const result = await window.easylens.settings.removeKey();
    if (!result.ok) {
      setMessage(result.error || '移除失败。', 'error');
      return;
    }
    applySettings(result.settings);
    setMessage('密钥已移除，翻译已切回本地词典。', 'success');
  } catch (error) {
    setMessage(`移除失败：${error.message}`, 'error');
  }
});

closeButton.addEventListener('click', () => {
  window.easylens.settings.close();
});

refresh();
