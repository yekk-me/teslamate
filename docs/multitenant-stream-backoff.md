# Streaming owner API retry backoff

The multitenant stream client previously closed and immediately reconnected when
Tesla returned an `owner_api error`, including 403/unauthorized. Repeated failures
could generate several requests per second and consume substantial node CPU.

Consecutive failures now delay subscription by 30, 60, 120, 240, then 300 seconds.
A successful WebSocket handshake or control frame does not reset this delay;
valid vehicle data does. Timers keep manual disconnect responsive, and stale
subscription messages cannot bypass the delay. This bounds retries; it does not
repair the underlying Tesla authorization failure.

Warnings include the internal tenant ID, a numeric Tesla vehicle ID when
available, HTTP status, and retry delay. Raw upstream responses, credentials and
VINs are not included in this warning. Runtime logger metadata is configured as
well as compile-time metadata because the multitenant image overlays the existing
release.

## Verification

- The immediate-resubscription regression fails against the original stream
  module and passes after the change.
- 18 tests pass across the stream callback, vehicle streaming and multitenant API
  suites, using a disposable local PostgreSQL instance.
- The broader API suite has an existing failure in `ApiTest` when the API
  GenServer does not exist. The original API module reproduces this failure.
- Release smoke checks validate cooldown and log metadata on arm64 and amd64.
  Local amd64 emulation needs `ERL_FLAGS="+JMsingle true"`; this is a test setting,
  not a production image setting.

## Publication

Publish both linux/amd64 and linux/arm64 to the existing Aliyun repository tag
`mytess/teslamate-multitenant:v2.2-multitenant`. The pre-change registry digest is
`sha256:509d8662d10681feac40f755258a8cd1c71943674acb2b97dd036b98de407052`.
The release build pins that existing image as `TESLAMATE_BASE_IMAGE` so its native
runtime and dependencies remain unchanged, and uses
`TESLAMATE_HEX_MIRROR=https://repo.hex.pm` when the default mirror is unavailable.

Publishing the tag does not replace running containers. Existing production
nodes must not be pulled, recreated or restarted as part of this release.
