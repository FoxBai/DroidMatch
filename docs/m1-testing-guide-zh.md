# M1 测试指南

本指南提供运行 M1 设备测试的分步说明，这些测试满足 `docs/m1-device-matrix.md` 中定义的退出标准。

## 前置要求

- 一个或多个物理 Android 设备（见下面的设备要求）
- USB 线缆连接且设备已通过 `adb devices -l` 授权
- 已安装 Debug APK（`tools/run-m1-device-smoke.sh` 会自动处理安装）

如果已安装 `adb` 但不在 `PATH` 中，可以导出 `DROIDMATCH_ADB`，或给快速场景包装脚本传入 `--adb`：

```bash
tools/quick-test-scenarios.sh handshake-stability \
  --adb "$HOME/Library/Android/sdk/platform-tools/adb" \
  --serial <serial> \
  --device-slot D \
  --max-list-ms 1000
```

`tools/run-m1-device-smoke.sh` 也会从 `$ANDROID_HOME`、`$ANDROID_SDK_ROOT` 或
`~/Library/Android/sdk` 自动发现 `adb`。

## 设备要求

M1 需要至少三个物理设备，覆盖这些槽位：

| 槽位 | Android API | 设备类型 | 用途 |
|---|---|---|---|
| A | API 26-29 | 传统存储时代手机 | 验证最低支持版本的 SAF/MediaStore 行为 |
| C | API 33-35 | 最新主流手机 | 验证当前权限提示和 AOA 可行性 |
| D | API 30+ | 非 Google OEM 或平板 | 验证厂商 USB 行为和大容量存储 |

当前测试覆盖：
- ✅ Slot D: NIO N2301, API 34（已记录多个测试）
- ⚠️ Slot A: 尚无测试记录
- ⚠️ Slot C: 尚无测试记录（除非 NIO N2301 也充当此角色）

## 关键 M1 退出标准测试

同一组检查也可以通过快速场景包装脚本运行：

```bash
tools/quick-test-scenarios.sh help
tools/quick-test-scenarios.sh handshake-stability --serial <serial> --device-slot D --max-list-ms 1000
tools/quick-test-scenarios.sh full-matrix --serial <serial> --device-slot D
```

### 1. 握手稳定性测试

**目标：** 验证 ADB 握手在 20 次尝试中至少成功 19 次。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --handshake-attempts 20 \
  --min-handshake-passes 19 \
  --list-path dm://media-images/ \
  --max-list-ms 1000
```

**预期结果：**
- 脚本输出显示 `handshake attempts: 19-20/20 passed`（至少 19 次）
- 首次目录列表报告的 harness `elapsed_ms` ≤ 1000（对于预热服务）。结果日志也会单独记录命令外层 wall time；gate 使用 harness elapsed time，避免 SwiftPM/进程启动开销污染设备延迟断言。如果失败，保留结果日志并把它当作延迟问题处理，而不是握手问题。
- 结果日志写入 `fixtures/m1-runs/`

### 2. 下载吞吐量测试

**目标：** 验证 100MB ADB 下载吞吐量 ≥ 20 MiB/s。

**设置：**
首先，在 app sandbox 中准备一个 100MB 测试文件：
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --adb-baseline-download-check \
  --resume-check \
  --chunk-size-bytes 1048576 \
  --min-download-mib-per-second 20
```

**作用：**
- 在 `dm://app-sandbox/dm-100mb-zero.bin` 创建 100MiB 零填充文件
- 记录同一 app-sandbox 文件的原始 ADB `exec-out run-as ... cat` 下载基线
- 运行故意部分下载，然后恢复
- 使用 1MiB 块（Android 当前协商的最大值）
- 断言吞吐量 ≥ 20 MiB/s
- 在结果日志中记录 `elapsed_ms` 和 `throughput_mib_per_sec`

**预期结果：**
- 下载完成，`throughput_mib_per_sec` ≥ 20.0
- 结果日志包含 M1 计时指标和 ADB baseline 下载吞吐
- 测试在至少 3 个所需设备上通过

### 3. 上传吞吐量测试

**目标：** 验证 100MB app-sandbox 上传吞吐量。

**设置：**
创建本地 100MB 测试文件：
```bash
dd if=/dev/zero of=/tmp/droidmatch-100mb-upload.bin bs=1048576 count=100
```

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --min-upload-bytes 104857600 \
  --chunk-size-bytes 1048576 \
  --min-upload-mib-per-second 20 \
  --cleanup-upload-destination
```

**预期结果：**
- 上传完成并记录 `throughput_mib_per_sec`
- 结果日志包含 `elapsed_ms` 和 `throughput_mib_per_sec`
- 清理自动删除上传的文件

### 4. 下载恢复测试

**目标：** 验证中断的下载从已接受的偏移量恢复，无数据损坏。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --resume-check \
  --chunk-size-bytes 1048576
```

**作用：**
- 部分下载（默认：停在 1 字节后）
- 创建带源指纹的 sidecar
- 从部分偏移量恢复
- 验证最终文件完整性

**预期结果：**
- 部分下载留下 `.droidmatch-part` 和 `.droidmatch-transfer.json`
- 恢复命令成功完成，`final_offset=104857600`
- 无数据损坏

### 5. 上传恢复测试

**目标：** 验证中断的 app-sandbox 上传恢复并提交最终目标。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --upload-resume-check \
  --upload-partial-bytes 1048576 \
  --chunk-size-bytes 1048576 \
  --cleanup-upload-destination
```

**作用：**
- 部分上传（停在 1MiB 后）
- 创建 `.droidmatch-upload-transfer.json` sidecar
- 从部分偏移量恢复
- 验证 Android 提交最终文件

**预期结果：**
- 部分上传创建 Android 隐藏 `.droidmatch-upload-part`
- 恢复完成，`final_offset=104857600`
- Android 原子替换目标文件

### 6. 传输丢失恢复测试

**目标：** 验证基于 sidecar 的重试在传输丢失后重新连接。

**带故障注入的下载：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --prepare-app-sandbox-file dm-100mb-zero.bin \
  --resume-check \
  --download-retry-fault-check \
  --chunk-size-bytes 1048576 \
  --max-retry-attempts 3 \
  --retry-backoff-ms 100
```

**带故障注入的上传：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-100mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-100mb-upload.bin \
  --upload-resume-check \
  --upload-retry-fault-check \
  --chunk-size-bytes 1048576 \
  --max-retry-attempts 3 \
  --retry-backoff-ms 100 \
  --cleanup-upload-destination
```

**作用：**
- 通过 `tools/m1-fault-proxy.py` 路由传输
- 代理在第 3 个服务器帧后断开首次传输连接
- Mac harness 检测丢失并使用 sidecar 重试；不传 `--max-retry-attempts`
  时保持历史单次重试，上面的示例会把可配置恢复队列策略写进结果日志
- 要求最终输出包含 `recovered=true`

**预期结果：**
- 尽管注入断开，传输仍完成
- Harness 输出包含 `recovered=true`
- 展示对线缆拔插的弹性

### 7. 上传 ACK 丢失恢复测试

**目标：** 验证 app-sandbox 上传通过截断和重放容忍 ACK 丢失。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-10mb-upload.bin \
  --upload-destination-path dm://app-sandbox/dm-10mb-upload-ack-loss.bin \
  --upload-resume-check \
  --upload-retry-ack-loss-check \
  --chunk-size-bytes 1048576 \
  --cleanup-upload-destination
```

**作用：**
- 通过丢弃第一个 ACK 的代理路由上传
- Android 写入块但 Mac 不推进偏移量
- Mac 重试，Android 将部分截断回确认的偏移量
- 验证接受重复块

**预期结果：**
- 尽管第一个 ACK 丢失，上传仍完成
- 展示 Android 写入和 Mac ACK 之间的窗口容忍度

### 8. 权限撤销测试

**目标：** 验证 media root 列表在撤销后返回 `permissionRequired`。

**命令：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --media-permission-revoked-check \
  --list-path dm://media-images/
```

**作用：**
- 记录当前 media 权限
- 撤销 `READ_MEDIA_IMAGES`、`READ_MEDIA_VIDEO` 和相关权限
- 要求 `list-dir dm://media-images/` 返回错误码 `permissionRequired`
- 测试后恢复原始权限

**预期结果：**
- ListDir 在撤销期间失败，返回 `ERROR_CODE_PERMISSION_REQUIRED`
- 权限自动恢复
- Android endpoint 可能需要在恢复后重启

**MediaStore 下载期间撤销：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --source-path dm://media-images/media/<id> \
  --destination /tmp/droidmatch-media-revoke-during-download.jpg \
  --chunk-size-bytes 1048576 \
  --media-permission-revoked-during-download-check
```

**作用：**
- 通过本地 frame-aware fault proxy 路由 media 下载
- 在前几个 proxied 下载 chunk 后撤销当前 media 读取权限
- 接受完整下载，或预期内的 transport-loss 错误
- 检查后恢复原始 media 授权

**预期结果：**
- 当前 Slot D NIO N2301 记录为 `transport_lost_after_revoke`
- 日志包含权限变更、fault-proxy hook status 和恢复输出
- 不要把这个检查和吞吐/最小字节 gate 混用；此运行验证权限变化行为，不验证完整文件传输性能

### 9. 预期错误边界测试

**目标：** 记录缺失源、未授权根和不支持操作的稳定错误映射。

**列出缺失的 SAF 根：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --list-expect-error-path dm://saf-missing/ \
  --list-expect-error-code notFound
```

**下载缺失文件：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --download-open-expect-error-path dm://app-sandbox/missing-file.bin \
  --download-open-expect-error-code notFound
```

**MediaStore fresh-only 上传恢复：**
```bash
tools/run-m1-device-smoke.sh \
  --serial <serial> \
  --upload-source /tmp/droidmatch-upload.jpg \
  --upload-destination-path dm://media-images/droidmatch-test.jpg \
  --upload-resume-unsupported-check \
  --min-upload-bytes 1 \
  --cleanup-upload-destination
```

**预期结果：**
- 每个测试记录预期的错误码和可选消息子串
- 证明协议为明确定义的失败案例返回稳定的类型化错误

## 测试矩阵建议

对于跨三个设备的完整 M1 验证：

1. **Slot A 设备（API 26-29）：**
   - 握手稳定性（20 次尝试）
   - 100MB 下载吞吐量
   - 100MB 上传吞吐量
   - 下载恢复
   - 上传恢复

2. **Slot C 设备（API 33-35）：**
   - 与 Slot A 相同，加上：
   - 权限撤销测试
   - MediaStore 下载期间权限撤销
   - 预期错误边界
   - Fresh MediaStore 上传
   - 传输丢失恢复

3. **Slot D 设备（国产 OEM 或平板）：**
   - 握手稳定性
   - 大目录列表（如果可用）
   - 100MB 吞吐量测试
   - 厂商特定行为验证

## 结果日志

所有测试将脱敏后的日志写入 `fixtures/m1-runs/`，除非传递 `--no-result-log`。

提交日志前：
```bash
bash tools/check-m1-run-logs.sh
```

这确保日志不包含：
- 完整设备序列号（应该脱敏）
- 个人文件路径
- 未脱敏的支持包

## 当前测试覆盖状态

基于 `fixtures/m1-runs/` 中的现有日志：
- ✅ App-sandbox 上传（fresh、resume、100MB）
- ✅ 下载 cancel 和 pause
- ✅ MediaStore 上传 fresh-only 边界
- ✅ Slot D 握手稳定性（NIO N2301 20/20 次尝试）
- ✅ 带 `recovered=true` 的传输丢失恢复
- ✅ Slot D ADB baseline 下载诊断（同一个 100MiB app-sandbox 文件达到 75.70 MiB/s）
- ✅ Slot D 100MB 窗口化下载断言（1MiB chunk 下 48.95 MiB/s，高于 20）
- ✅ Slot D 100MB 窗口化上传断言（1MiB chunk 下 33.51 MiB/s，高于 20）
- ✅ Slot D 预热 media-images 列表断言（harness `elapsed_ms=98`，低于 1000）
- ✅ Slot D Media 权限撤销（`permissionRequired`，并恢复原授权）
- ✅ Slot D MediaStore 下载期间权限撤销（`transport_lost_after_revoke`，并恢复原授权）
- ❌ **缺失：** Slot A 和 Slot C 设备上的握手稳定性及更完整矩阵覆盖
- ❌ **缺失：** 上传/下载期间 USB 拔插

## 下一步

设备可用时优先运行的测试：

1. 添加 Slot A 设备（API 26-29）并运行基本矩阵。
2. 添加 Slot C 设备（API 33-35）并运行带权限测试的完整矩阵。
3. 记录上传/下载期间 USB 拔插的行为。
4. 记录每个设备的吞吐量结果和 USB 时序。

这将满足 `docs/m1-device-matrix.md` 中定义的 M1 退出标准。
