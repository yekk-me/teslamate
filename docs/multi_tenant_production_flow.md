# TeslaMate Multi-Tenant Production Flow

The JSON file directory is for local smoke tests only. In production, TeslaMate
should read tenant assignments from the control plane over HTTP.

## Runtime Configuration

Set the multi-tenant TeslaMate node with:

```bash
TESLAMATE_MULTI_TENANT=true
TESLAMATE_TENANT_DIRECTORY_URL=https://control.internal/teslamate/tenants
TESLAMATE_TENANT_DIRECTORY_TOKEN=...
TESLAMATE_INTERNAL_API_TOKEN=...
TESLAMATE_TENANT_DB_POOLER=pgbouncer
TESLAMATE_TENANT_REPO_POOL_SIZE=1
TESLAMATE_TENANT_START_WEB=true
```

`TESLAMATE_TENANT_DIRECTORY_URL` must return:

```json
{
  "tenants": [
    {
      "id": "tenant-a",
      "status": "active",
      "database": {
        "host": "pgbouncer",
        "port": 6432,
        "username": "teslamate_a",
        "password": "secret",
        "name": "teslamate_tenant_a",
        "pooler": "pgbouncer",
        "pool_size": 1
      },
      "mqtt": {
        "host": "mqtt",
        "namespace": "tenant-a"
      },
      "entitlements": {
        "enabled": true,
        "logging": true
      },
      "limits": {
        "max_vehicles": 3,
        "tesla_api_requests_per_minute": 120,
        "mqtt_publishes_per_minute": 600
      },
      "vehicles": []
    }
  ]
}
```

## New Tenant Authorization

1. Control plane creates the tenant database and runs TeslaMate migrations.
2. Control plane exposes the tenant in the directory with `vehicles: []`.
3. TeslaMate syncs the directory and starts the tenant Repo/API runtime.
4. User finishes Tesla OAuth in the control plane.
5. Control plane calls TeslaMate:

```bash
curl -X POST https://teslamate.internal/api/internal/tenants/tenant-a/authorize \
  -H "Authorization: Bearer $TESLAMATE_INTERNAL_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "access_token": "...",
    "refresh_token": "..."
  }'
```

TeslaMate validates the token, stores it encrypted in the tenant database, and
returns vehicle assignments:

```json
{
  "data": {
    "tenant_id": "tenant-a",
    "vehicles": [
      {
        "id": "123",
        "eid": "123",
        "vid": "456",
        "vin": "5YJ...",
        "display_name": "Model Y",
        "state": "online",
        "status": "active"
      }
    ]
  }
}
```

6. Control plane lets the user select vehicles and writes them back into the
   tenant assignment.
7. TeslaMate syncs again, detects the tenant assignment changed, and starts the
   vehicle loggers and MQTT publishers for the selected vehicles.
