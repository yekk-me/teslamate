# 完整接收服务与账号实测

本分支自带官方接收器、Kafka、签名代理、桥接、TeslaMate 入库及账号测试工具。接收器和签名代理直接构建固定提交的 Tesla 官方源码，不重新实现车辆协议。车辆使用自己的证书，通过 mTLS WebSocket 连接你的接收域名；官方接收器负责验证车辆身份和解码，Kafka 保留消息，桥接按 VIN 投递到租户，原 TeslaMate 状态机生成记录。

## 两种部署

- 已有 Mytess 多租户环境：`deploy/fleet/compose.yml` 启动接收器、Kafka、签名代理和桥接，接入现有 TeslaMate Docker 网络。给已有 TeslaMate 挂载下文配置并逐租户执行数据库迁移。
- 独立账号实测：再叠加 `compose.account-test.yml`，同时构建本分支 TeslaMate 和独立 PostgreSQL，自动迁移独立测试库。只有 `fleet-test` 测试租户，使用文件目录，无需先开发账户中心；不连接原有数据库。

这是单机持久化部署，Kafka 数据和独立测试数据库都有命名卷。Kafka 默认保留 7 天；单副本不能抵抗磁盘损毁，不等同于生产高可用集群。不要执行 `down -v` 清理真实测试或生产数据。桥接仅消费 V 数据；connectivity 和 errors 保留在各自 Kafka 主题中用于诊断，不把断开连接误判为睡眠。

## 准备一次

1. 使用 Linux、Docker Engine、Compose **2.30+**、Python 3.10+、OpenSSL。检出 `codex/fleet-cn-multitenant`。首次构建会下载 Tesla 官方源码及依赖，服务器需要能访问 GitHub、镜像仓库及依赖源。
2. 在特斯拉中国开发者门户创建应用，启用 Authorization Code 和所需服务端认证方式，申请车辆数据及位置权限。
3. 准备两个用途的域名，可以放在不同主机：
   - `app.example.cn`：应用注册域名、公钥发布、OAuth HTTPS 回调。
   - `telemetry.example.cn`：车辆推送接收域名，DNS 直接指向服务器。TCP 443 直达接收器；不要启用 CDN HTTP 代理，不要由 Nginx HTTP 反代终止这条 mTLS 连接。
4. 为接收域名准备 PEM 证书链与对应私钥。`fullchain.pem` 要按官方证书检查要求包含完整链。若现有网站已占用同 IP 的 443，可使用独立服务器/IP，或明确设置另一个公网端口并在车辆配置中保持一致。
5. 独立测试先生成内部 API token 文件；已有环境使用当前 `TESLAMATE_INTERNAL_API_TOKEN` 的文件，不要生成不同的 token。文件不要加入 Git。

从仓库根目录执行（替换证书路径和域名）：

```bash
umask 077
openssl rand -hex 32 > /tmp/fleet-internal-token
python3 tools/fleet/setup.py \
  --hostname telemetry.example.cn \
  --cert /安全路径/fullchain.pem \
  --key /安全路径/privkey.pem \
  --internal-token-file /tmp/fleet-internal-token \
  --account-test
```

脚本检查证书主机名、有效期、证书与私钥匹配，生成 `deploy/fleet/runtime`。已有目录时拒绝覆盖，以免意外更换已配对的应用密钥。现有环境不要传 `--account-test`。

生成内容包括：接收器配置及证书、独立的 P-256 应用签名密钥、内部签名代理 TLS 证书、VIN 路由、车辆采样配置。代理 TLS 私钥与应用签名私钥是两个不同文件。

将 `runtime/public/com.tesla.3p.public-key.pem` **复制到应用域名的网站目录**，确保以下 URL 可公开读取：

```text
https://app.example.cn/.well-known/appspecific/com.tesla.3p.public-key.pem
```

这个文件只有公钥。不要发布 `runtime/command` 或整个 runtime 目录。

在 `runtime/account-test.env` 填写中国区 `TESLA_FLEET_CLIENT_ID`、`TESLA_FLEET_CLIENT_SECRET`，将 `TESLA_FLEET_REDIRECT_URI` 改成：

```text
https://app.example.cn/fleet/callback
```

开发者门户登记的回调地址必须完全相同。其他已生成的数据库密码和加密密钥保持固定，备份保管。给测试容器的 UID/GID 10000:10001 配置目录读取权限；以下只改变新建的测试目录：

```bash
sudo chgrp -R 10001 deploy/fleet/runtime/control
chmod 2750 deploy/fleet/runtime/control
chmod 640 deploy/fleet/runtime/control/tenants.json
```

文件目录挂载的是整个目录，授权工具原子更新 tenants.json 后，容器可以读到新文件。setgid 保证新文件继续由容器可读的组拥有。命令应由生成配置的同一用户执行。

## 启动完整测试环境

```bash
docker compose --env-file deploy/fleet/.env \
  -f deploy/fleet/compose.yml \
  -f deploy/fleet/compose.account-test.yml up -d --build
```

只对外开放接收器端口。测试 TeslaMate 的 14000 端口绑定本机；应用网站的 Nginx 可以仅代理回调路径：

```nginx
location = /fleet/callback {
    access_log off;
    proxy_pass http://127.0.0.1:14000;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto https;
}
```

回调页是账号测试工具的落地页，不会在网页输出 token。禁用此路径访问日志，防止 code/state 被反代日志记录。内部 `/api/internal/` 接口不要公开反代。

应用注册使用已有脚本。仅在当前 shell 配置中国应用凭据，然后执行一次：

```bash
python3 tools/fleet/provision.py register app.example.cn
```

`TESLA_FLEET_CLIENT_ID`、`TESLA_FLEET_CLIENT_SECRET` 必须在运行该脚本的 shell 环境中可用；Compose 的 env_file 不会自动加载到宿主机 shell。不要将密钥直接写入 shell 历史。

## 用自己的特斯拉账号授权

```bash
python3 tools/fleet/onboard.py authorize \
  --base-url http://127.0.0.1:14000 \
  --tenant fleet-test --vin 你的VIN \
  --directory-file deploy/fleet/runtime/control/tenants.json
```

工具打印中国区官方授权链接。浏览器打开后，用特斯拉账号登录并同意授权。跳转到回调页后，把**地址栏完整链接**粘贴回终端的隐藏输入。工具检查回调地址、state、拒绝授权和重复参数，再由 TeslaMate 兑换令牌；令牌加密保存在测试租户数据库，不返回终端。

只会将你指定且官方确实返回的 VIN 分配给测试租户，不会自动启用账号下所有车辆。工具同时更新 VIN 路由。等待至少一个租户同步周期（默认 15 秒），然后重新加载桥接：

```bash
docker compose --env-file deploy/fleet/.env \
  -f deploy/fleet/compose.yml \
  -f deploy/fleet/compose.account-test.yml restart fleet-bridge
```

若使用已有 HTTP 控制平面，不传 `--directory-file`；工具保存 `runtime/vehicle-assignment.json`，由现有控制平面持久化并同步。该模式不能跳过车辆分配这一步。

## 配对虚拟钥匙并下发推送配置

在手机打开官方配对链接，将域名替换为已注册且托管公钥的应用域名：

```text
https://tesla.com/_ak/app.example.cn
```

使用与 OAuth 相同的账号，在 Tesla App 中完成目标车辆配对。随后运行：

```bash
python3 tools/fleet/onboard.py configure \
  --base-url http://127.0.0.1:14000 \
  --tenant fleet-test --vin 你的VIN
```

内部接口检查租户权限和 VIN 分配，读取当前已保存令牌，通过内部 HTTPS 签名代理下发服务器端固定配置。调用者不能传任意 token、接收地址或采样字段。配置中的接收域名、端口和证书来自 setup.py 生成的文件。

工具最多等待约两分钟检查 `synced=true`；若尚未同步，返回非零退出码，不能把提交成功当作已同步。保持车辆正常在线，再查看：

```bash
python3 tools/fleet/onboard.py status \
  --base-url http://127.0.0.1:14000 \
  --tenant fleet-test --vin 你的VIN
```

输出车辆配置/同步状态、官方遥测错误和租户事件统计。若令牌刚好过期，内部 API 会触发刷新；等待后重试命令。不要为了等推送持续调用 wake_up。

## 已有多租户环境的接入差别

为 TeslaMate 增加以下环境及只读挂载；开启 `TESLAMATE_TENANT_START_WEB=true`，确保 bridge 可访问内部端口：

```yaml
environment:
  TESLA_FLEET_COMMAND_PROXY: https://fleet-command:4443
  TESLA_FLEET_PROXY_CA_FILE: /etc/fleet/proxy-ca.pem
  TESLA_FLEET_VEHICLE_CONFIG_FILE: /etc/fleet/vehicle-config.json
  TESLA_FLEET_TELEMETRY: "true"
  TESLAMATE_TENANT_START_WEB: "true"
volumes:
  - ./deploy/fleet/runtime/teslamate:/etc/fleet:ro
```

另外配置 OAuth 三个环境变量及与 bridge 一致的内部 API token。`deploy/fleet/.env` 中设置 `TESLAMATE_DOCKER_NETWORK`、必要时设置 `TESLAMATE_INTERNAL_URL`。先逐租户迁移数据库，再在停放、未充电时切换记录器；保留原数据库加密密钥。

## 验收和排障

- `synced=true` 且车在线时，`telemetry` 来源事件数量应增长；仅有 `snapshot` 来源说明 REST 正常，不能证明推送正常。
- `pending` 应持续消化；`late`、`incomplete` 需要检查，不能算已进入原报表。
- 检查接收器 TLS/车辆身份错误、Kafka lag、桥接路由及租户分配。未知 VIN 会阻塞该消费流程，修正路由后重启桥接。
- 真实车辆测试：一次完整行程、停车、AC 充电、DC 充电（如适用）、睡眠唤醒、断网重传。对比原始事件、positions/drives/charges/charging_processes 的时间、里程和电量。
- 证书续期后更新接收器证书，并评估车辆配置 ca 是否需要重新下发。代理测试证书默认一年有效；提前更换证书及 TeslaMate 信任文件并重启。应用签名密钥不能随 TLS 续期替换。

CI 使用隔离的模拟车辆证书运行真正的官方接收器、Kafka、签名代理和 PostgreSQL；测试 CA 只出现在临时测试配置，不加入生产配置。CI 验证无客户端证书被拒绝、官方二进制消息解码、可靠 ACK、Kafka 重启、HTTP 授权、租户入库、重复投递、消费进度和行程计算。OAuth/配置调用使用模拟官方响应测试；不冒充真实中国区账号验收。

仍然保留主文档说明的边界：Telemetry 行驶功率与旧字段不完全等价，迟到历史事件没有自动重建，缺失数据不能编造。完整部署和软件链路通过测试，不意味着所有车型/固件的数据精度已经通过实车验收。
