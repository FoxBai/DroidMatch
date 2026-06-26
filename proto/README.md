# DroidMatch 协议

协议使用 Protobuf 作为 schema 语言。M0 阶段不应把所有传输路径都绑定到 gRPC。

基本原则：

- Protobuf 消息定义请求、响应、事件、错误和能力。
- ADB TCP 通道后续可以按需要支持 gRPC 或 HTTP/2。
- AOA bulk 传输应先从轻量 frame 协议开始。
- 控制面和数据面必须保持可分离。
