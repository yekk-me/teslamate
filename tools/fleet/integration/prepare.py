"""Generate isolated test-only certificates. Never touches deployment runtime files."""
import json
import os
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from setup import initialize, openssl, write_json

out = Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
# A local CA with the issuer identity expected by the official test protocol.
openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=TeslaMotors", "-keyout", out/"ca-key.pem", "-out", out/"ca.pem")
for name, subject, extensions in [
    ("server", "localhost", "subjectAltName=DNS:localhost,DNS:fleet-telemetry\nextendedKeyUsage=serverAuth\n"),
    ("client", "LRW00000000000001", "extendedKeyUsage=clientAuth\n")]:
    openssl("req", "-new", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN="+subject, "-keyout", out/(name+"-key.pem"), "-out", out/(name+".csr"))
    (out/(name+".ext")).write_text(extensions)
    openssl("x509", "-req", "-in", out/(name+".csr"), "-CA", out/"ca.pem", "-CAkey", out/"ca-key.pem", "-CAcreateserial", "-days", "2", "-extfile", out/(name+".ext"), "-out", out/(name+".pem"))
(out/"fullchain.pem").write_text((out/"server.pem").read_text()+(out/"ca.pem").read_text())
(out/"token").write_text("isolated-fleet-smoke-token")
initialize(out, "localhost", out/"fullchain.pem", out/"server-key.pem", out/"token", 14443)
receiver = out/"runtime/receiver"
(receiver/"test-ca.pem").write_text((out/"ca.pem").read_text())
config = json.loads((receiver/"server.json").read_text())
config["tls"]["ca_file"] = "/etc/fleet/test-ca.pem"
write_json(receiver/"server.json", config)
write_json(out/"runtime/bridge/routes.json", {"LRW00000000000001":["smoke"]})
write_json(out/"host-consumer.json", {"bootstrap.servers":"localhost:19092", "group.id":"smoke"})
with (out/".env").open("a") as env:
    env.write("TESLAMATE_DOCKER_NETWORK=fleet-smoke-network\n")
# JSON is valid YAML; volume entries replace only the same container targets.
write_json(out/"override.json", {"services":{
    "kafka": {"ports":["127.0.0.1:19092:19092"], "environment":{
        "KAFKA_LISTENERS":"PLAINTEXT://:9092,CONTROLLER://:9093,HOST://:19092",
        "KAFKA_ADVERTISED_LISTENERS":"PLAINTEXT://kafka:9092,HOST://localhost:19092",
        "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP":"CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT,HOST:PLAINTEXT"}},
    "fleet-telemetry":{"volumes":[str(receiver)+":/etc/fleet:ro"]},
    "fleet-command":{"ports":["127.0.0.1:14444:4443"], "volumes":[str(out/"runtime/command")+":/keys:ro"]}
}})

def record(sec, values):
    minute, second = divmod(sec, 60)
    data = []
    for key, value in values.items():
        kind = "shiftStateValue" if key == "Gear" else "doubleValue"
        data.append({"key":key, "value":{kind:value}})
    return {"createdAt":f"2026-01-01T00:{minute:02}:{second:02}Z", "data":data}
records = [
    record(1, {"Gear":"ShiftStateD", "VehicleSpeed":30}),
    record(61, {"Odometer":10001.123456, "IdealBatteryRange":199, "RatedRange":189}),
    record(121, {"Gear":"ShiftStateP", "VehicleSpeed":0, "Odometer":10002.123456, "IdealBatteryRange":198, "RatedRange":188})]
# Deliberate retransmission; official receiver adds certificate-authenticated VIN.
write_json(out/"records.json", records + [records[-1]])
print("Prepared isolated mTLS fixtures and production Compose override")
