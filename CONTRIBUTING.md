# 参与贡献

欢迎通过 Issue 和 Pull Request 参与 KesonMount 的开发。为了让协作顺畅，请花一分钟看完这里。

## 开发环境

- macOS 14 或更新版本
- 命令行工具：`xcode-select --install`（不需要完整 Xcode）
- 源码可以放在网络盘上，但**构建产物必须在本机磁盘生成**，脚本已经处理

## 本地构建与检查

```bash
./build.sh --no-open   # 编译并安装到 /Applications，不自动打开
./scripts/check.sh     # 提交前必跑：类型检查 / UI 语法 / 版本一致性 / 桥接对照 / 回归测试
./tests/run.sh         # 只跑回归测试
```

`check.sh` 通过后才能提 PR。CI 会在 macOS 14 runner 上跑同一套检查。

发布新版本时，请同步更新 `.gitignore` 里允许入库的说明书 PDF 文件名，并把新版本 PDF 提交进仓库——否则别人 clone 后构建出的 App 会缺少内置说明书。

## 提交 Pull Request

1. 先开 Issue 说明问题或想法，避免重复劳动；大改动建议先讨论方案。
2. Fork 仓库，从 `main` 切出独立分支，例如 `fix/watchdog-retry`。
3. 一个 PR 只做一件事；描述里写清「为什么改」「怎么验证」。
4. 不要提交以下内容：
   - 任何账号、密码、钥匙串内容、个人 NAS 地址
   - `~/Library/Application Support/KesonMount/drives.json` 等本机配置
   - `dist/` 下的 DMG / PKG 和 `.app` 构建产物
5. 提交即表示你同意把自己的贡献按本仓库的 [MIT 许可证](LICENSE) 发布。

## 报告问题

用 Issue 反馈时请附上：macOS 版本、App 版本、复现步骤、预期行为、实际行为。日志和诊断报告请先自查脱敏——诊断导出本身会脱敏，但截图里可能带主机名或账号。

安全问题**不要**发公开 Issue，按 [SECURITY.md](SECURITY.md) 的方式私下报告。

## 行为准则

参与即表示你同意遵守 [行为准则](CODE_OF_CONDUCT.md)。
