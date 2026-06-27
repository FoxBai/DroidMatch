# DroidMatch

DroidMatch 是一款面向 macOS 的现代 Android 设备管理客户端。

项目目标是构建一个 Apple Silicon 原生、稳定、快速、可诊断的 HandShaker 现代替代品。DroidMatch 复刻的是有价值的用户工作流，而不是旧品牌、旧视觉资产、旧二进制实现或旧 UI。

详见 [docs/handshaker-relationship.md](docs/handshaker-relationship.md)：DroidMatch 与 HandShaker 的关系是工作流替代，不是代码、品牌、资产或二进制延续。

## 项目方向

- 本地优先，USB 优先，默认零云依赖。
- Mac 端与 Android 端双端重写。
- ADB 是稳定兼容路径。
- AOA 是低门槛消费级连接路径，但必须由 PoC 数据验证。
- v1.0 聚焦连接、文件、基础媒体浏览、传输恢复、诊断、签名与分发。
- 屏幕镜像、通知镜像、剪贴板同步、文件夹订阅和 Wi-Fi 是 v1.5+ 候选能力。

## 仓库结构

```text
DroidMatch/
├── android/
├── mac/
├── proto/
├── docs/
├── tools/
├── fixtures/
└── .github/workflows/
```

## M0 目标

M0 是规格阶段。只有当下面的问题都能被文档清楚回答时，M0 才算完成：

- DroidMatch v1.0 做什么、不做什么？
- Mac、Android、协议和传输层的模块边界是什么？
- ADB 与 AOA 如何发现设备、握手、重连和失败？
- 协议如何处理版本协商、请求取消和大文件传输？
- Android 权限不足时如何降级？
- M1 如何在真机上验收？

从 [docs/m0-checklist.md](docs/m0-checklist.md) 开始。

M0 已收口，结论见 [docs/m0-closeout.md](docs/m0-closeout.md)。下一阶段从 M1 harness 和 [docs/m1-device-matrix.md](docs/m1-device-matrix.md) 开始。
