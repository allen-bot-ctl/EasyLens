# Electron 主线、无发布验证与云端发版

- GitHub 默认分支仍为 `master`。Electron 源码是生产入口；`feat/gbot` 与所有公开标签保留；Swift 原型和 macOS 划选助手共用的 Swift 源码保留。不重写已发布版本。
- `Verify` 只响应本仓库所有者对 `master`、`integration/electron-master` 的推送，检出事件的完整 SHA。运行本项目测试、Linux OCR/打包/进程冒烟、Windows 安装包构建及 macOS 打包/验签；不创建 Release、不上传下载包、不触发 Pages 或更新源。可信的 macOS 签名验证使用仓库已有 Secrets，签名不等于公证或真实升级。
- Mac 测试解压本轮实际 x64 / arm64 ZIP，确认哈希、版本、架构及客户端验签；在临时副本上替换签名，确认客户端拒绝。CI 不会操作用户 Mac 或改设置。Windows/Linux 只提示更新、进入下载页；macOS 实机还需验证安装、升级和系统授权。
- Pages 发布仅来自 `master`，且推送只在官网文件或 Pages 工作流变化时触发。上传和部署分离；部署前用同一运行 ID 验证 `github-pages` 产物存在。若仍失败，先检查各步骤日志，不把 GitHub 产品下载页和 Pages 状态混为一谈。
- 发版仅针对已通过 `master` 上 Verify 的精确提交，`package.json` 版本、对应发行说明与正式 tag 一致。Release 使用同一构建链，签名、ZIP 与原样发布资产名不变。发布前复查远端 tag 不漂移、版本严格高于现有最新、Release 尚未存在。历史已发布标签不修改。旧标签保留旧提交上的工作流；不从历史 `feat/gbot` 创建新的正式标签，本流程不改变仓库所有者已有权限。
- 云端发布入口：仅在用户明确要求发版、或已有覆盖该版本的授权时，向 `release-requests` 的既有 `.github/release-request.json` 写一条请求。仓库所有者的单文件 push 触发无权限信号；默认分支的控制器读取该次提交的 JSON，不执行请求分支代码或读取它的产物。
- 例：`{"mode":"dry-run","tag":"v0.1.15","commit":"<master 的完整 40 位 SHA>"}`。首次正反预检完成并启用后，`dry-run` 仍不创建标签。明确发版时 `mode` 用 `publish`，控制器创建新标签并向 `master` 的 Release 工作流传入相同 tag/SHA。控制器成功只表示已派发；必须再读取 Release 任务、GitHub 公开资产、更新源；不能用它推断已安装。
- 恢复：暂停时把请求文件写回 `{"disabled":true}`，检查无已排队发布，然后在 `master` 把 publish job 的 if 恢复 `false && needs.validate.outputs.mode == 'publish'`。如标签已生成但未发布，先核对原 SHA 和同标签任务，不删或移动标签；如果此前 SHA 仍是 master 且已授权恢复，可在 Actions 对原 tag/SHA 手动派发，否则留住标签单独审查。已经发版的回退应走新的修正版，不能移动历史标签。
