"""Run real receiver -> Kafka -> HTTP inbox -> PostgreSQL projection checks."""
import json
import os
import ssl
import subprocess
import sys
import time
from pathlib import Path
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[3]
out = Path(os.environ["FLEET_SMOKE_DIR"])
compose = ["docker", "compose", "--env-file", str(out/".env"), "-f", str(ROOT/"deploy/fleet/compose.yml"), "-f", str(out/"override.json")]
processes = []
logs = []


def spawn(command, name, env=None):
    log = (out/name).open("w")
    logs.append(log)
    process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    processes.append(process)
    return process


def wait_for(predicate, seconds=90):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if predicate():
            return
        for p in processes:
            if p.poll() not in (None, 0):
                raise RuntimeError("Integration child failed; inspect smoke logs")
        time.sleep(1)
    raise TimeoutError("Integration readiness/result timeout")


def proxy_ready():
    # Verify proxy certificate and health endpoint; no real token or cloud request.
    context = ssl.create_default_context(cafile=str(out/"runtime/teslamate/proxy-ca.pem"))
    import socket
    try:
        with socket.create_connection(("localhost", 14444), timeout=3) as tcp:
            with context.wrap_socket(tcp, server_hostname="fleet-command") as tls:
                tls.sendall(b"GET /health HTTP/1.1\r\nHost: fleet-command\r\nConnection: close\r\n\r\n")
                return b"200" in tls.recv(1024).split(b"\r\n")[0]
    except OSError:
        return False

try:
    wait_for(proxy_ready)
    inbox_env = dict(os.environ, TESLAMATE_INTERNAL_API_TOKEN="isolated-fleet-smoke-token")
    spawn(["mix", "run", "--no-start", "tools/fleet/integration/inbox.exs"], "inbox.log", inbox_env)
    wait_for(lambda: (out/"inbox-ready").exists())
    # Check internal API authentication on the real HTTP listener.
    try:
        urlopen("http://127.0.0.1:14000/api/internal/tenants/smoke/fleet/status")
        raise AssertionError("Unauthenticated inbox status accepted")
    except __import__("urllib.error", fromlist=["HTTPError"]).HTTPError as error:
        assert error.code == 401
    sender = [str(out/"vehicle-client"), str(out), str(out/"records.json")]
    subprocess.run(sender, check=True)
    # Receiver ACKs must survive a broker process restart before consumption.
    subprocess.run(compose+["restart", "kafka"], check=True)
    subprocess.run(compose+["up", "-d", "--wait", "kafka"], check=True)
    bridge_env = dict(os.environ, KAFKA_CONSUMER_CONFIG=str(out/"host-consumer.json"),
                      FLEET_VIN_ROUTES=str(out/"runtime/bridge/routes.json"),
                      TESLAMATE_INTERNAL_URL="http://127.0.0.1:14000",
                      TESLAMATE_INTERNAL_API_TOKEN_FILE=str(out/"token"))
    bridge = spawn(["python3", "tools/fleet/bridge.py"], "bridge.log", bridge_env)
    (out/"check").touch()
    wait_for(lambda: (out/"result.json").exists())
    before = json.loads((out/"result.json").read_text())
    # Replay all wire messages, then restart the consumer: no duplicate rows.
    subprocess.run(sender, check=True)
    from confluent_kafka import Consumer, TopicPartition
    checker = Consumer({"bootstrap.servers":"localhost:19092", "group.id":"smoke", "enable.auto.commit":False})
    def caught_up():
        metadata = checker.list_topics("teslamate_V", timeout=5)
        partitions = [TopicPartition("teslamate_V", n) for n in metadata.topics["teslamate_V"].partitions]
        offsets = checker.committed(partitions, timeout=5)
        for p in offsets:
            high = checker.get_watermark_offsets(p, timeout=5)[1]
            if not (p.offset == high or (high == 0 and p.offset < 0)):
                return False
        return True
    wait_for(caught_up)
    checker.close()
    bridge.terminate(); bridge.wait(timeout=10)
    processes.remove(bridge)
    spawn(["python3", "tools/fleet/bridge.py"], "bridge-restart.log", bridge_env)
    time.sleep(3)
    after = json.loads((out/"result.json").read_text())
    assert before == after, (before, after)
    print(json.dumps({"result":"PASS", "verified":["mTLS required", "official wire decoding", "Kafka reliable ACK", "broker restart durability", "internal bearer auth", "real tenant PostgreSQL inbox", "drive distance and timestamps", "wire retransmission deduplication", "consumer restart", "command proxy TLS health"], "database":after}, indent=2))
finally:
    for p in reversed(processes):
        if p.poll() is None:
            p.terminate()
            try: p.wait(timeout=10)
            except subprocess.TimeoutExpired: p.kill()
    for log in logs: log.close()
