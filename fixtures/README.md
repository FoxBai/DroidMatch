# 测试固件

这里存放测试固件。

M1 期间优先记录真实 harness 结果：

- `m1-runs/`：按 `docs/m1-device-matrix.md` 的模板记录真机运行结果。
- `protocol/`：后续放可被脚本验证的 Protobuf fixture，不放会漂移的手写样例。
- `legacy-research/`：仅当 M0.5 继续推进时，存放行为级研究笔记；不得存放旧代码、旧二进制或旧资源。

当前 M0 阶段不要求固件齐全；固件应随 M1 harness 一起生成和验证。
