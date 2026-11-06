'use strict';

const { contextBridge, ipcRenderer } = require('electron');

function subscribe(channel, callback) {
  if (typeof callback !== 'function') return () => {};
  const listener = (_event, payload) => callback(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('easylens', {
  platform: process.platform,
  onLensState: (callback) => subscribe('lens:state', callback),
  onLensSuppress: (callback) => subscribe('lens:suppress', callback),
  onLensResume: (callback) => subscribe('lens:resume', callback),
  onCardShow: (callback) => subscribe('card:show', callback),
  lensReady: () => ipcRenderer.send('lens:ready'),
  resizeCard: (size) => ipcRenderer.send('card:resize', size),
  settings: {
    get: () => ipcRenderer.invoke('settings:get'),
    save: (payload) => ipcRenderer.invoke('settings:save', payload),
    removeKey: () => ipcRenderer.invoke('settings:remove-key'),
    test: () => ipcRenderer.invoke('settings:test'),
    openLog: () => ipcRenderer.invoke('settings:open-log'),
    close: () => ipcRenderer.invoke('settings:close')
  }
});
