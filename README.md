# 网络透镜 · Network Lens

[![CI](https://github.com/six-walnut/network-lens/actions/workflows/ci.yml/badge.svg)](https://github.com/six-walnut/network-lens/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)

**公司网络又不稳定？先看看问题更可能发生在哪一层。**

Network Lens 是一个本地优先的 macOS 桌面网络监测工具：从本机、网关、DNS、外网到指定网站，持续显示观测结果与疑似故障依据，而不是只给一个“已断网”。

> A compact, local-first macOS network monitor. Observe your gateway, system DNS, direct TCP connectivity and selected HTTP endpoints, with evidence-based diagnostics, incident history and JSON reports.

## 特性

- **190 × 190 pt 桌面组件**：拖动定位、暂停/继续、深浅色、透明度、可选置顶，菜单栏常驻。
- **分层探测**：默认网关 ICMP、系统解析器、两个独立外网 TCP 目标、1–5 个自定义 HTTP(S) 网站。
- **降低误报**：连续三轮同类异常才确认；连续两轮可达才确认恢复；网关禁 ping 不直接判定断网。
- **有依据的诊断**：单个目标异常、直连受限、DNS 失败和出口异常分别展示，并提示 VPN/代理的影响。
- **本地历史**：延迟趋势、异常事件、JSON 导出与日志轮转。
- **原生、无第三方运行时依赖**：Swift、SwiftUI、AppKit、Network.framework。

这是**独立桌面悬浮应用**，不是系统“添加小组件”列表中的 WidgetKit 扩展。

## 下载与安装

在 [Releases](https://github.com/six-walnut/network-lens/releases) 下载 `NetworkLens-v1.1.0-macOS-arm64.zip`，解压后将 `NetworkLens.app` 放入“应用程序”，双击启动。

- 预编译包：**Apple Silicon / macOS 13+**，实际在 macOS 26.6.2 arm64 验证。
- 当前是测试版，使用 **ad-hoc 本地签名，未经过 Apple Developer ID 签名或公证**。Gatekeeper 可能阻止打开。可选择从源码构建；不需要关闭系统安全保护。
- 如果系统请求本地网络权限，用途是探测本地网关与配置的内网站点。
- 通知和登录启动默认关闭，由用户自行启用。
- Release 附 `SHA256SUMS.txt`，可用 `shasum -a 256 -c SHA256SUMS.txt` 校验下载内容。

## 从源码构建

需要 macOS、Xcode 或 Apple Command Line Tools。构建脚本使用当前机器架构。

```sh
git clone https://github.com/six-walnut/network-lens.git
cd network-lens
./build.sh
open dist/NetworkLens.app
```

也可设置 `ARCH=arm64` 或 `ARCH=x86_64` 交叉编译；跨架构运行需要对应硬件或 Rosetta。Intel 及较旧 macOS 尚未完成实机验证。

## 测试

```sh
./build.sh
dist/NetworkLens.app/Contents/MacOS/NetworkLens --self-test
python3 Tests/test_http.py
```

39 项确定性检查涵盖故障分层、稳定性、设置校验与事件持久化；5 项回环 HTTP 集成测试涵盖 200、503、405、302 与超时。CI 不主动运行公网网络探测。

手动实际诊断：

```sh
dist/NetworkLens.app/Contents/MacOS/NetworkLens --probe-once
```

此命令会访问默认探测目标，并输出本机接口/IP 等信息，请勿将未检查的结果直接贴到公开 Issue。

## 隐私与边界

- 不抓包、不读取浏览历史、不修改 DNS/路由/代理，也不上传诊断日志。
- **监测本身会发送请求**：默认探测系统网关、`www.apple.com`、`1.1.1.1:443`、`8.8.8.8:443`、`https://www.apple.com` 和 `https://www.baidu.com`。
- 网站使用无 Cookie/保存凭据的 HEAD 请求；HTTPS 保持系统证书验证。不跟随重定向，不把认证门户误当目标健康。
- 日志保存在 `~/Library/Application Support/NetworkLens/`，报告含本机 IP、网关和目标主机；分享前请脱敏。
- 网站 URL 查询参数不进入报告，但会保存在本机设置中。建议不要在检测地址中放置密钥。
- 两个外网 TCP 目标当前固定，企业防火墙可能限制；系统 DNS 可命中缓存；HTTP 可达不等于业务功能正常。
- 状态判断是**疑似原因与观测证据**，不是对网络故障责任方的确定归因。请遵守所在网络的使用规则。

## 项目结构

```text
Sources/       探测引擎、桌面界面、记录与导出
Tests/         Swift 确定性测试、Python 回环 HTTP 测试
Assets/        App 图标及其生成源码
docs/          使用指南、验证范围与发布说明
.github/       自动构建与测试
build.sh       无第三方依赖的本地构建脚本
```

## 文档与贡献

- [完整使用说明](docs/usage.zh-CN.md)
- [验证范围与已知限制](docs/validation.zh-CN.md)
- [更新日志](CHANGELOG.md)
- [贡献指南](CONTRIBUTING.md)
- [安全报告](SECURITY.md)

欢迎提交经过脱敏的 Bug 报告和 Pull Request。软件和仓库内原创图标源码以 [MIT License](LICENSE) 发布。
