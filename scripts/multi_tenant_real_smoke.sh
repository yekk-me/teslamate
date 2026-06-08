#!/usr/bin/env bash
set -euo pipefail

ENV_FILE="${1:-.local/teslamate-mt-real.env}"
WORK_DIR="${SMOKE_WORK_DIR:-.local/multi-tenant-real-smoke}"
NETWORK="${SMOKE_DOCKER_NETWORK:-tm-mt-real-smoke}"
POSTGRES_CONTAINER="${SMOKE_POSTGRES_CONTAINER:-tm-mt-real-postgres}"
PGBOUNCER_CONTAINER="${SMOKE_PGBOUNCER_CONTAINER:-tm-mt-real-pgbouncer}"
MQTT_CONTAINER="${SMOKE_MQTT_CONTAINER:-tm-mt-real-mqtt}"
APP_CONTAINER="${SMOKE_APP_CONTAINER:-tm-mt-real-app}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:18-alpine}"
MOSQUITTO_IMAGE="${MOSQUITTO_IMAGE:-eclipse-mosquitto:2}"
ELIXIR_IMAGE="${ELIXIR_IMAGE:-elixir:1.18.4-otp-26}"
USE_PGBOUNCER="${USE_PGBOUNCER:-1}"
SMOKE_SECONDS="${SMOKE_SECONDS:-180}"
TENANT_DB="${SMOKE_TENANT_DATABASE:-teslamate_mt_real_a}"
TENANT_DIRECTORY="$WORK_DIR/tenant-directory.json"
HEX_ARCHIVE="${HEX_ARCHIVE:-/tmp/hex-2.4.2-otp-26.ez}"

if [[ ! -f "$ENV_FILE" ]]; then
  cat >&2 <<EOF
Missing env file: $ENV_FILE

Create it locally with:
  ENCRYPTION_KEY=...
  TESLA_ACCESS_TOKEN=...
  TESLA_REFRESH_TOKEN=...

Optional:
  TESLA_VIN=...
  USE_PGBOUNCER=1
  SMOKE_SECONDS=180
EOF
  exit 1
fi

mkdir -p "$WORK_DIR"

cleanup() {
  docker rm -f "$APP_CONTAINER" "$POSTGRES_CONTAINER" "$PGBOUNCER_CONTAINER" "$MQTT_CONTAINER" \
    >/dev/null 2>&1 || true
  docker network rm "$NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup
docker network create "$NETWORK" >/dev/null

cat >"$WORK_DIR/mosquitto.conf" <<'EOF'
listener 1883
allow_anonymous true
EOF

docker run -d \
  --name "$POSTGRES_CONTAINER" \
  --network "$NETWORK" \
  -e POSTGRES_PASSWORD=postgres \
  "$POSTGRES_IMAGE" >/dev/null

docker run -d \
  --name "$MQTT_CONTAINER" \
  --network "$NETWORK" \
  -v "$PWD/$WORK_DIR/mosquitto.conf:/mosquitto/config/mosquitto.conf:ro" \
  "$MOSQUITTO_IMAGE" >/dev/null

for i in $(seq 1 30); do
  if docker exec "$POSTGRES_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
  if [[ "$i" == "30" ]]; then
    echo "Postgres did not become ready" >&2
    exit 1
  fi
done

TENANT_DATABASE_HOST="$POSTGRES_CONTAINER"
TENANT_DATABASE_PORT="5432"
TENANT_DATABASE_POOLER=""

if [[ "$USE_PGBOUNCER" == "1" ]]; then
  cat >"$WORK_DIR/pgbouncer-userlist.txt" <<'EOF'
"postgres" "postgres"
EOF

  cat >"$WORK_DIR/pgbouncer.ini" <<EOF
[databases]
* = host=$POSTGRES_CONTAINER port=5432 user=postgres password=postgres

[pgbouncer]
listen_addr = 0.0.0.0
listen_port = 6432
pool_mode = transaction
auth_type = plain
auth_file = /etc/pgbouncer/userlist.txt
max_client_conn = 2000
default_pool_size = 20
reserve_pool_size = 5
server_reset_query = DISCARD ALL
ignore_startup_parameters = extra_float_digits
EOF
  chmod 644 "$WORK_DIR/pgbouncer.ini" "$WORK_DIR/pgbouncer-userlist.txt"

  docker build -t tm-mt-pgbouncer-smoke -f - "$WORK_DIR" <<'EOF'
FROM alpine:3.20
RUN apk add --no-cache pgbouncer
RUN adduser -D -H pgbouncer || true
USER pgbouncer
ENTRYPOINT ["pgbouncer"]
EOF

  docker run -d \
    --name "$PGBOUNCER_CONTAINER" \
    --network "$NETWORK" \
    -v "$PWD/$WORK_DIR/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini:ro" \
    -v "$PWD/$WORK_DIR/pgbouncer-userlist.txt:/etc/pgbouncer/userlist.txt:ro" \
    tm-mt-pgbouncer-smoke /etc/pgbouncer/pgbouncer.ini >/dev/null

  TENANT_DATABASE_HOST="$PGBOUNCER_CONTAINER"
  TENANT_DATABASE_PORT="6432"
  TENANT_DATABASE_POOLER="pgbouncer"
fi

mix_docker() {
  if [[ -n "${MIX_DOCKER_NAME:-}" ]]; then
    docker run --rm \
      --name "$MIX_DOCKER_NAME" \
      --network "$NETWORK" \
      --env-file "$ENV_FILE" \
      -v "$PWD":/work \
      -v "$HEX_ARCHIVE:$HEX_ARCHIVE:ro" \
      -w /work \
      -e MIX_ENV=dev \
      -e LOGGER_LEVEL="${LOGGER_LEVEL:-warning}" \
      -e TESLA_API_HTTP_DEBUG=false \
      -e HEX_OFFLINE=1 \
      -e SKIP_LOCALE_DOWNLOAD=true \
      -e DATABASE_HOST="$POSTGRES_CONTAINER" \
      -e DATABASE_PORT=5432 \
      -e DATABASE_USER=postgres \
      -e DATABASE_PASS=postgres \
      -e DATABASE_NAME="$TENANT_DB" \
      -e TENANT_DIRECTORY_PATH="/work/$TENANT_DIRECTORY" \
      -e TENANT_DATABASE_HOST="$TENANT_DATABASE_HOST" \
      -e TENANT_DATABASE_PORT="$TENANT_DATABASE_PORT" \
      -e TENANT_DATABASE_USER=postgres \
      -e TENANT_DATABASE_PASS=postgres \
      -e TENANT_DATABASE_POOLER="$TENANT_DATABASE_POOLER" \
      -e TENANT_MQTT_HOST="$MQTT_CONTAINER" \
      -e TENANT_MQTT_PORT=1883 \
      "$ELIXIR_IMAGE" sh -lc "mix archive.install $HEX_ARCHIVE --force >/dev/null && (mix local.rebar --force >/dev/null 2>&1 || true) && $*"
  else
    docker run --rm \
      --network "$NETWORK" \
      --env-file "$ENV_FILE" \
      -v "$PWD":/work \
      -v "$HEX_ARCHIVE:$HEX_ARCHIVE:ro" \
      -w /work \
      -e MIX_ENV=dev \
      -e LOGGER_LEVEL="${LOGGER_LEVEL:-warning}" \
      -e TESLA_API_HTTP_DEBUG=false \
      -e HEX_OFFLINE=1 \
      -e SKIP_LOCALE_DOWNLOAD=true \
      -e DATABASE_HOST="$POSTGRES_CONTAINER" \
      -e DATABASE_PORT=5432 \
      -e DATABASE_USER=postgres \
      -e DATABASE_PASS=postgres \
      -e DATABASE_NAME="$TENANT_DB" \
      -e TENANT_DIRECTORY_PATH="/work/$TENANT_DIRECTORY" \
      -e TENANT_DATABASE_HOST="$TENANT_DATABASE_HOST" \
      -e TENANT_DATABASE_PORT="$TENANT_DATABASE_PORT" \
      -e TENANT_DATABASE_USER=postgres \
      -e TENANT_DATABASE_PASS=postgres \
      -e TENANT_DATABASE_POOLER="$TENANT_DATABASE_POOLER" \
      -e TENANT_MQTT_HOST="$MQTT_CONTAINER" \
      -e TENANT_MQTT_PORT=1883 \
      "$ELIXIR_IMAGE" sh -lc "mix archive.install $HEX_ARCHIVE --force >/dev/null && (mix local.rebar --force >/dev/null 2>&1 || true) && $*"
  fi
}

mix_docker "mix ecto.create --quiet && mix ecto.migrate --quiet"
mix_docker "mix run --no-start scripts/multi_tenant_real_prepare.exs"

docker run --rm \
  --network "$NETWORK" \
  "$MOSQUITTO_IMAGE" mosquitto_sub -h "$MQTT_CONTAINER" -t 'teslamate/#' -v -C 1 -W "$SMOKE_SECONDS" \
  >"$WORK_DIR/mqtt-message.log" 2>"$WORK_DIR/mqtt-sub.log" &
MQTT_SUB_PID=$!

set +e
MIX_DOCKER_NAME="$APP_CONTAINER" mix_docker "TESLAMATE_MULTI_TENANT=true \
  TESLAMATE_TENANT_DIRECTORY=/work/$TENANT_DIRECTORY \
  TESLAMATE_TENANT_START_WEB=false \
  TESLAMATE_TENANT_START_MQTT=true \
  TESLAMATE_TENANT_VEHICLE_RUNTIME=logger \
  TESLAMATE_TENANT_DB_POOLER=$TENANT_DATABASE_POOLER \
  mix run --no-halt" &
APP_PID=$!

for _ in $(seq 1 "$SMOKE_SECONDS"); do
  if [[ -s "$WORK_DIR/mqtt-message.log" ]]; then
    break
  fi

  if ! kill -0 "$APP_PID" >/dev/null 2>&1; then
    break
  fi

  sleep 1
done

docker stop --time 10 "$APP_CONTAINER" >/dev/null 2>&1 || kill "$APP_PID" >/dev/null 2>&1 || true
wait "$APP_PID"
APP_STATUS=$?
wait "$MQTT_SUB_PID"
MQTT_STATUS=$?
set -e

if [[ -s "$WORK_DIR/mqtt-message.log" ]]; then
  echo "MQTT message observed:"
  sed -n '1,3p' "$WORK_DIR/mqtt-message.log"
else
  echo "No MQTT message observed within ${SMOKE_SECONDS}s; see $WORK_DIR for logs" >&2
fi

if [[ "$APP_STATUS" -ne 0 && "$APP_STATUS" -ne 137 && "$APP_STATUS" -ne 143 ]]; then
  echo "TeslaMate smoke process exited with status $APP_STATUS" >&2
  exit "$APP_STATUS"
fi

if [[ "$MQTT_STATUS" -ne 0 && "$MQTT_STATUS" -ne 27 ]]; then
  echo "MQTT subscriber exited with status $MQTT_STATUS" >&2
fi

echo "Smoke test finished. Runtime files are under $WORK_DIR"
