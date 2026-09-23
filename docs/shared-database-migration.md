# 历史数据库迁移到共享 schema

工具 `tools/shared/migrate.py` 只复制和验证，不删除源库、不激活目的端。使用与服务器主版本相同的 PostgreSQL 客户端。首先部署共享节点并完成 public 基线初始化；不能把源库直接恢复到正在运行的 shared public schema。

## 复制

1. 完整备份车辆源库、控制面数据库、原租户分配和 API 通知配置。记下原 node ID、数据库连接、加密密钥和镜像版本。测试恢复备份。
2. 进入维护窗口，停止原租户记录器和 API 的全部写入。暂停相关 Fleet bridge 消费以让 Kafka 保留消息，不要用租户撤销 tombstone 代替迁移暂停（撤销表示可丢弃后续消息）。停止源节点的所有自动重建/续费同步任务，避免切换期间重新启动旧写入端。
3. 通过受保护的环境文件/交互方式设置 `SOURCE_DATABASE_URL` 与 `SHARED_ADMIN_DATABASE_URL`；后者需要临时创建 staging 数据库和角色的管理员权限。不要把 DSN 放进命令参数或 Git。
4. 执行：

```bash
python3 tools/shared/migrate.py \
  --tenant-id 实际租户ID --runtime-role shared_runtime \
  --source-stopped --work-dir /安全备份目录/该租户迁移
```

工具创建源库 custom dump，在隔离 staging 数据库重命名 schema，再恢复到目标的 `tenant_<SHA256前128位>` 和对应 `_private`。数据不是 SQL 文本替换；同一租户的 ID/外键不改变，不同租户的 id=1 可以共存。扩展保留在 public。源库存在 public/private 以外的用户 schema 时拒绝迁移，避免遗漏未评估的数据。

`verification.json` 必须为 `verified: true`，且 source、destination、source_after 三份逐表行数/SHA256和序列信息一致。包含 numeric 小数、浮点数、微秒时间戳、密文和序列的 CI 用例已覆盖。工具另有完整 TeslaMate schema（类型、函数和扩展依赖）恢复测试。大表校验需要扫描/排序，给维护窗口和临时磁盘留足空间。

任何错误均不激活新分配；保留 work-dir 供检查。目标已存在时拒绝覆盖。失败可能留下尚未激活的目标角色/schema；核实名称和备份后单独处理，不要直接重跑覆盖。staging 数据库在退出时清理。

## 切换控制面与 API 配置

采用新的共享节点，与原节点分开。先在共享节点开通一个无真实车辆的模板租户，确认 schema、API AK/SK、共同 API URL 和 MQTT 正常。控制面全量备份之后，停止控制/agent 自动同步，在维护事务中将已验证租户的分配切换到共享节点：

- `tenants.node_id` 改为新共享节点。
- `tenant_database_host/port/user/pass/name/pooler` 使用共享模板租户的值。`pass` 列是由控制面密钥加密后的值，**不可写入明文**；同一控制面内复制模板租户的密文即可。
- `raw.multi_tenant_assignment.database` 使用模板的对象，但 `schema` 必须是验证报告中该租户自己的值，不是模板的 schema。
- MQTT host/port 使用共享 broker，namespace 保留该租户唯一值；对应 raw assignment 同步更新。共享 API 的 domain/route 使用共同入口配置，AK/SK 保留各自凭据，不可复制模板的 AK/SK。
- 此时租户仍保持暂停。使用 mytess-admin 的 `deploy/shared/adopt.sql` 进行上述事务；脚本拒绝 active 租户、同一源/模板租户和错误 schema。该脚本只修改控制元数据，不触碰车辆数据库，必须先核实复制报告。

```bash
# 用环境变量提供控制数据库连接；变量示例均是标识，不含密码。
psql -X -v ON_ERROR_STOP=1 \
  -v tenant_id=实际租户ID -v template_id=已验证共享模板租户ID \
  -v verified_schema=verification.json中的schema \
  -f /mytess-admin路径/deploy/shared/adopt.sql
```

将原 API 通知配置目录复制到共享 API `NOTIFICATION_CONFIG_DIR/<schema>`，保留设备/订阅配置，设置 UID/GID 10001 可读写；不要同时运行旧 API 通知任务。恢复控制/agent 后执行节点重新同步，它会为复制的 schema 补齐分支新增迁移并导出 API/VIN 路由。确认 schema 与复制报告一致，再通过管理端恢复租户。

如果旧数据只有 Owner token，Fleet provider 检查会拒绝使用它；必须在 Mytess App 重新完成官方 OAuth。令牌密钥不同也应重新授权，不能把解密失败当作没有车辆。完成虚拟钥匙和 Telemetry 配置后恢复 bridge 消费。原数据库继续保留为只读备份。

## 核验与回滚

比较源/目标车辆数、行程/充电数量、最近时间、里程和耗电统计；检查同 ID 的另一租户完全不可见。核验 App 历史页面、MQTT 当前状态、通知接收设备以及 APNS 只触发一次。数据库侧检查连接数量由池上限限制。

切换前失败：恢复旧进程与 bridge，源数据未被修改。切换后若新端已有写入，不能直接回到旧库，否则丢失切换后的数据；先暂停新写入，备份两端和 Kafka offset，再做增量补录/验证。只有确认目标尚无新数据时，才可从控制面备份恢复原分配并恢复旧端。旧 Owner 采集器不能作为 Fleet 授权回滚目标；回滚部署须同样支持 Fleet。
