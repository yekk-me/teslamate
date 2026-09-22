# 中国区 Fleet API / Fleet Telemetry 迁移

基于 `mytesla/v2.2-multitenant`。运行时只使用特斯拉中国官方接口，不再连接 Owner API 或旧版 streaming 服务。原有 positions、drives、charges、charging_processes、states 和 updates 表及其单位、精度、统计 SQL 保留；新增原始数据收件箱和处理检查点。

## 当前边界

Fleet REST 模式沿用原有记录状态机，适合先完成官方授权迁移。Fleet Telemetry 模式使用同一个状态机，由持久化事件驱动，并定期用官方 REST 补充数据。两个模式由同一个车辆监督树选择，不能同时运行两个记录器。

**不能声称推送与旧接口全部字段、全部时间点完全等价。** 官方遥测没有可直接等同于旧 `drive_state.power` 的字段；不能把 PackCurrent × PackVoltage 冒充原来的行驶功率。推送样本的该字段留空，官方 REST 样本仍记录实际返回值。因此只启用低频 REST 时，功率最大值、均值的采样覆盖会变化。车型/固件不支持的字段也不能凭空补出。上线前必须按下文用目标车型验证。

超过排序窗口才到达的事件会保留为 `late`，不会回写已经结束的行程，也不会错误地并入当前行程；**当前没有自动重建历史行程的功能**。缺少位置、里程、续航、挡位或充电关键字段的事件标记 `incomplete`，原始数据完整保留。这两类状态需要监控，不能当作所有数据已计入统计。车辆或服务未发送的数据不能通过 REST 追回。

## 配置

在现有多租户 TeslaMate 服务增加：

```dotenv
TESLA_FLEET_CLIENT_ID=中国开发者应用的客户端ID
TESLA_FLEET_CLIENT_SECRET=客户端密钥
TESLA_FLEET_REDIRECT_URI=https://你的账户中心/tesla/callback
TESLA_FLEET_PORTAL_URL=https://你的账户中心/车辆授权
TESLA_FLEET_TELEMETRY=false
TESLA_FLEET_RECONCILE_SECONDS=300
TESLA_FLEET_REORDER_SECONDS=10
```

`TESLA_FLEET_TELEMETRY=false`：官方 Fleet REST，保持原记录轮询策略。

`true`：官方推送驱动记录；每 300 秒查询车辆状态，只有在线才请求 vehicle_data。不调用 wake_up。补充周期最低 30 秒；429 按 Retry-After 延后。排序窗口默认 10 秒，可在有实测网络延迟后调大，代价是展示延迟。

原有 `TESLA_API_HOST`、`TESLA_AUTH_HOST`、`TESLA_WSS_HOST`、第三方 `TOKEN` 不再生效。数据接口固定 `https://fleet-api.prd.cn.vn.cloud.tesla.cn`，授权与刷新固定 `https://auth.tesla.cn/oauth2/v3`。密钥只从服务环境读取，回调不能覆盖授权服务器、client_id 或 redirect_uri。

迁移会给已有 private.tokens 标记 `owner`，这些令牌不会发给 Fleet API，所有租户需要重新授权。新 Fleet 令牌继续用原有 Vault 加密保存；刷新后先持久化再更新运行中 API 进程。

## 账户中心接入

本分支已有控制平面式多租户管理；授权绑定由账户中心完成。不要向浏览器暴露 `TESLAMATE_INTERNAL_API_TOKEN`。

1. 账户中心确认当前用户属于目标租户，建立该租户运行时及数据库。
2. 服务端携带内部 Bearer token 请求 `POST /api/internal/tenants/{tenant_id}/fleet/authorize`，获得 `data.authorization_url`，跳转到这个官方地址。state 仅存哈希、有效 10 分钟、仅可使用一次。
3. 账户中心将 state 与自己的登录会话及 tenant_id 绑定。回调时同时校验该绑定；**不能只相信浏览器提交的 tenant_id**。
4. 服务端请求 `POST /api/internal/tenants/{tenant_id}/authorize`，JSON 为 `{"code":"官方回调code","state":"原state"}`。服务校验租户内 state、兑换令牌、查询车辆，并安装到该租户的 API 进程。
5. 按原控制平面流程持久化返回的车辆分配并触发租户同步。调用者不能再提交 Owner access/refresh token。

请求的用户授权范围为 `openid offline_access vehicle_device_data vehicle_location`。OAuth 注册回调必须与环境值完全一致。账户中心必须处理拒绝授权、过期 state 和重新授权；不应记录 code、state 或令牌。登录页可通过 `TESLA_FLEET_PORTAL_URL` 指向账户中心。

## 官方推送服务器

数据链路：车辆 → 特斯拉官方 fleet-telemetry 接收器（终止车辆 mTLS）→ Kafka → 本仓库 bridge → 租户 PostgreSQL 收件箱 → 原记录状态机。

这不是向 TeslaMate 随意配置一个公网 webhook。`/api/internal/.../fleet/events` 仅供可信桥接服务使用，不能直接暴露给车辆或公共客户端。

1. 在 [特斯拉中国开发者门户](https://developer.tesla.cn/) 创建应用，配置域名、回调、数据与位置权限。
2. 按 [官方接收器说明](https://github.com/teslamotors/fleet-telemetry) 生成 P-256 应用密钥，在注册应用域名的 `/.well-known/appspecific/com.tesla.3p.public-key.pem` 提供**公钥**。签名私钥仅供 vehicle-command proxy 使用，与接收器的 TLS 私钥是两回事。
3. 设置上述 CLIENT_ID/SECRET 后运行 `python3 tools/fleet/provision.py register 你的应用域名`。脚本只向中国区申请 partner token 和注册，不输出令牌。
4. 用户在 Tesla App 中给车辆配对应用虚拟钥匙。按官方工具检查车辆与固件支持情况。
5. 部署官方 [vehicle-command proxy](https://github.com/teslamotors/vehicle-command/tree/main/cmd/tesla-http-proxy)，配置中国 Fleet 上游与应用签名私钥。不要关闭 TLS 校验。
6. 部署官方接收器。参考 `deploy/fleet/server.json.example`；本文核对的官方源码版本为 `8fbaa100bd365936dab6ecbf0e2d7070c4d765cb`。设置 `transmit_decoded_records=true` 和 `reliable_ack_sources={"V":"kafka"}`。TLS 必须在接收器终止，四层代理可以转发，不要让普通七层代理剥离车辆证书。
7. 配置持久化 Kafka，预建 `teslamate_V`、`teslamate_connectivity` 主题。V 的 partition key 必须保持官方 VIN，使用持久磁盘、适当保留期以及生产所需副本/最小同步副本；接收器成功写 Kafka 后才向车辆确认。接收器不使用 stdout 或易失性 Pub/Sub 作为确认依据。
8. 复制 `deploy/fleet/{server,consumer,routes}.json.example` 为相应 `.json`，填写 Kafka 与 VIN→租户路由。共享 VIN 可以对应多个被授权租户。路由文件来自可信账户中心，桥接还会校验 Kafka key 与 payload VIN 相同；服务再次核对租户当前车辆分配与权限。
9. 把内部 API token 写入权限受控的 `deploy/fleet/internal_api_token`。部署时让 bridge 的 UID 10001 可读。复制 TLS 证书到配置目录。设置 `FLEET_TELEMETRY_IMAGE` 为已验证并固定版本/摘要的官方镜像，再运行 `docker compose -f deploy/fleet/compose.yml up -d`。Kafka 和 TeslaMate 必须在该配置可达的网络中。
10. 使用该用户的官方 Fleet access token 文件设置 `TESLA_FLEET_ACCESS_TOKEN_FILE`，并设置可信的 `TESLA_FLEET_COMMAND_PROXY=https://...`；自签代理证书用 `TESLA_FLEET_PROXY_CA_FILE` 指定信任 CA。复制 vehicle-config 示例并填写接收器主机名与完整 PEM 证书链。串行运行 `python3 tools/fleet/provision.py configure VIN vehicle-config.json`，然后 `python3 tools/fleet/provision.py status VIN`。必须检查 skipped_vehicles 及 `synced=true`，不能把 HTTP 200 当作车辆已配置成功。
11. 完成字段验证后，在车辆停放且未充电时把 `TESLA_FLEET_TELEMETRY` 改为 true 并重启租户运行时。先迁移数据库，再启动新代码；不要在进行中的行程/充电过程中切换记录器。

桥接消费进度只在目标租户全部返回 `stored` 或 `duplicate` 后同步提交。请求超时、租户不可用、未知 VIN、路由错误会退出等待监督器重试，不跳过数据；修正路由后重启即可。更新 routes 后需重启 bridge。Kafka 保留期应覆盖最长预期停机，数据库与 Kafka 均需备份。

## 字段与精度

| 官方信号/接口 | 写入现有模型 | 处理 |
| --- | --- | --- |
| vehicle_data | 原有 TeslaApi.Vehicle 结构 | 原解析与记录计算继续使用 |
| Location | latitude / longitude | 原始 WGS84，不做 GCJ-02 偏移 |
| VehicleSpeed | speed | 输入 mph，仍由原 Convert 转 km/h |
| Odometer | odometer | 输入英里，原转换保留 6 位 km |
| IdealBatteryRange / RatedRange / EstBatteryRange | 原三个续航字段 | 原转换及数据库精度 |
| BatteryLevel / Soc | battery_level / usable_battery_level | 保留现有整数列；原始小数另存 inbox |
| DCChargingEnergyIn | charge_energy_added | 电池侧 kWh，适用于 AC 与 DC |
| ACChargingEnergyIn | 只存原始信号 | 充电器侧电量，不能替代电池侧值 |
| ACChargingPower / DCChargingPower | charger_power | 按充电类型映射到原整数 kW；原值留存 |
| Gear / DetailedChargeState | 行程与充电状态机 | 未知值不能当成 P 或充电结束 |
| Version | 软件版本 | 沿用原版本补记机制；REST 补充软件更新状态 |
| 温度、胎压 | 原字段 | 摄氏度、bar，不额外换算 |
| createdAt | 数据时间 | UTC 车辆时间，received_at 单独保存 |

温度、锁车、胎压等与当前行驶/充电采样无关的增量只更新缓存（`cached`），避免这些字段的推送频率改变统计样本权重。

字段未出现表示没有新变化，不清空已有值；显式 invalid 会清空该字段并阻止依赖它的不完整记录。启动时缺少完整基础字段，需要首个官方 REST 快照或足够的推送字段才能产生记录。新充电会话不能复用上次累计电量。

车辆配置示例对位置、挡位、速度、里程设 1 秒最小间隔，充电数据 5 秒；为里程/续航/电量显式设置很小的 minimum_delta，避免固件默认阈值造成隐含降采样。实际发送仍遵循官方“变化时发送”的规则。更高频率与更多字段不一定更便宜，成本取决于车辆数量、字段变化和 REST 次数，需实测。

## 验证与监控

```sh
MIX_ENV=test mix test
python3 -m unittest discover -s tools/fleet/tests -v
```

专项回归覆盖单位/精度、显式 invalid、充电会话重置、AC/DC 电量区别、按车辆时间排序、重复投递、重启恢复、跨 VIN 拒绝、事务回滚，以及桥接失败不提交 offset。原状态机的行程、充电、休眠、更新、租户测试继续执行。

内部 `GET /api/internal/tenants/{tenant_id}/fleet/status` 返回按车辆、数据来源和状态分组的数量及时间范围。监控 `pending` 积压、`late`、`incomplete`，以及 Kafka lag、接收器车辆连接/字段错误、OAuth 失败。incomplete 后来的完整事件不会自动把之前的数据伪装成完整记录。

生产验收至少需要真实中国区应用及目标车辆：完整驾驶、停车、AC/DC 充电、休眠唤醒、断网重传、接收器/Kafka/数据库重启。对比时间、轨迹点、里程、续航差、电池侧充入电量及会话数量，检查全部 required 字段；功率覆盖差异单独评估。仓库自动化测试不能替代这一验收，也不能证明每种固件都有相同字段。

## 参考

- [TeslaMate 官方 API 配置](https://docs.teslamate.org/docs/configuration/api/)
- [TeslaMate 开发与数据记录](https://docs.teslamate.org/docs/development/)
- [中国区第三方 OAuth](https://developer.tesla.cn/docs/fleet-api/authentication/third-party-tokens)
- [中国区 partner token](https://developer.tesla.cn/docs/fleet-api/authentication/partner-tokens)
- [车辆与 telemetry 配置接口](https://developer.tesla.cn/docs/fleet-api/endpoints/vehicle-endpoints)
- [Fleet Telemetry 字段含义](https://developer.tesla.com/docs/fleet-api/fleet-telemetry/available-data)
- [官方接收器与 Kafka 可靠确认](https://github.com/teslamotors/fleet-telemetry)

TeslaMate 指南中较旧的推送频率描述与当前 Tesla 文档存在差别；采样和字段含义以特斯拉当前文档及车辆实际固件为准。
