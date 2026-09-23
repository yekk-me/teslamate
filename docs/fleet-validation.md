# Fleet 中国区迁移验证记录

基础分支：`mytesla/v2.2-multitenant`，基础提交 `49afed642cbf773f5fa8dabf5d45bb61e403ac6a`。
实现分支：`codex/fleet-cn-multitenant`。

2026-09-22，GitHub Actions 的 Elixir 1.19.5 / OTP 28 / PostgreSQL 16 环境验证：

- 编译成功。
- Fleet 专项 18 项通过：官方中国 OAuth 参数、令牌错误脱敏、拒绝旧 Owner 令牌、state 一次性/过期、数据字段/单位、充电会话、真实数据库事务回滚、跨租户 VIN 拒绝、重复/迟到处理、检查点恢复、REST 与推送派生记录对照、微秒时间和无关信号不增加采样。
- 全套 ExUnit：382 项，0 失败（包含上述 18 项）。
- Python Kafka bridge：5 项，0 失败，验证多租户确认、失败重试、VIN 核验与消费进度提交顺序。
- 配置 JSON 全部通过解析检查。

通过的实现提交：`7d71a1380478a6c9426f48d4bbbd9a4f48e5f8e6`。
[对应 CI 记录](https://github.com/yekk-me/teslamate/actions/runs/35754882471)。之后的整理提交将格式检查改为只检查、不修改代码；最新分支仍由同一专用工作流验证。

为了让目标分支已有测试可执行，修正了其过期测试夹具：英文 UI 测试显式使用英文 locale、熔断器名称加入已有的 single 租户前缀、地理编码 mock 对齐该分支已有地址、离线边界用例以最后一个样本的毫秒为起点，以及 Settings 用例对齐该分支已经移除上游版本栏/页脚的布局。没有跳过或删除测试。生产语言与地理编码地址没有因此改变。

原 DevOps 工作流的 Nix lint 在加载开发环境时失败：锁定的 nixpkgs 不含 `beamPackages.elixir_1_19`。这属于现有 Nix 配置与版本的矛盾，专用 Fleet 流程直接安装相同 Elixir/OTP 后执行完整测试。Elixir 1.19 也报告了原代码的结构体类型检查警告；编译成功不表示零警告。

## 尚未执行与不能据此推断的内容

本次没有中国区真实应用密钥、已授权车辆、公网 mTLS 接收器或生产 Kafka，因此没有执行真实车辆授权、虚拟钥匙配对、实际推送/重传、车型固件兼容性和费用验收。Kafka bridge 的上述测试使用受控 consumer/message 对象，不能称为生产 Kafka 端到端测试。

严格的全字段/全时间点等价尚未成立：遥测行驶功率缺乏直接等价字段，低频官方 REST 只能补充其实际采样点；超过排序窗口的迟到事件完整保留，但尚未自动重建历史行程。不能将这两项标记为已解决。部署、数据精度映射、监控与车辆验收步骤见 [中国区部署指南](fleet-api-cn.md)。

在真实车辆验收之前，推送投影保持显式启用；默认使用官方 Fleet REST。现有行程/充电历史表未被批量重写。


## 完整接收链路补充验证（2026-09-23）

提交 `193516c27307a343eb3286f9e7c62f8c9d82ebf5` 的 [CI 35807575760](https://github.com/yekk-me/teslamate/actions/runs/35807575760) 两项任务成功：385 项 Elixir 测试、7 项 Python 测试，以及真实官方接收器 / Kafka / 签名代理 / PostgreSQL 联调。

联调由临时测试 CA 签发模拟车辆证书，使用官方 protobuf + FlatBuffers 编码和 mTLS WebSocket 发送 3 个驾驶事件及重复消息。验证无车辆证书被拒绝、Kafka 写入后的可靠 ACK、消费者启动前重启 Kafka 不丢消息、内部 HTTP Bearer 校验、租户实际入库、投递重放去重、消费者重启以及原行程计算。最终 4 个唯一事件（含 1 个 REST 基准快照）、1 条行程，里程 3.218688 km，起止时间与输入一致。

这里没有调用真实 Tesla 账号或真实车辆。独立账号测试环境及操作流程见 `fleet-account-test.md`；真实车辆授权、虚拟钥匙配对、车型字段和中国网络连接验收仍需用户环境。
