'use strict';
// 0.1.9（照搬栏历 0.1.52）：electron-builder afterSign 钩子。CI 设了 EASYLENS_SIGN_IDENTITY 时，
// 用固定的自签证书「EasyLens Self-Signed」重签（在打 dmg/zip 之前，x64 和 arm64 各跑一次）：
//   1. 先签 .app 里内嵌的 macos-selection-reader（electron-builder 的临时签名会覆盖它，
//      而它放在 Resources 里，codesign --deep 不一定会去签）；
//   2. 再 --deep 签整个 .app。
// 这样 designated requirement 是「identifier + certificate leaf」，升级后屏幕录制和辅助功能授权保留。
// 本地没设这个变量时什么也不做，仍是临时签名。
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');

exports.default = async function stableSign(context) {
  const id = process.env.EASYLENS_SIGN_IDENTITY;
  if (!id || context.electronPlatformName !== 'darwin') return;
  const app = path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`);
  const args = ['--force', '--sign', id, '--timestamp=none'];
  if (process.env.EASYLENS_SIGN_KEYCHAIN) args.push('--keychain', process.env.EASYLENS_SIGN_KEYCHAIN);

  const reader = path.join(app, 'Contents', 'Resources', 'app', 'electron', 'bin', 'macos-selection-reader');
  if (fs.existsSync(reader)) {
    execFileSync('codesign', [...args, reader], { stdio: 'inherit' });
    console.log('[stable-sign] 已用固定证书重签 macos-selection-reader');
  } else {
    console.log('[stable-sign] 未找到内嵌的 macos-selection-reader，跳过');
  }

  execFileSync('codesign', [...args, '--deep', app], { stdio: 'inherit' });
  // --deep 重签后再确认一次 reader 仍是固定证书（--deep 可能会碰它）。
  if (fs.existsSync(reader)) {
    execFileSync('codesign', [...args, reader], { stdio: 'inherit' });
    execFileSync('codesign', [...args, app], { stdio: 'inherit' });
  }
  execFileSync('codesign', ['--verify', '--deep', '--strict', app], { stdio: 'inherit' });
  console.log(`[stable-sign] 已用固定证书重签 ${path.basename(app)}`);
};
