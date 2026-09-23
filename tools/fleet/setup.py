#!/usr/bin/env python3
"""Generate the complete Fleet receiver stack configuration (never overwrites keys)."""
import argparse
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def openssl(*args):
    return subprocess.run(["openssl", *map(str, args)], check=True, capture_output=True).stdout


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")
    path.chmod(0o600)


def initialize(target, hostname, cert, key, token, port=443):
    if not re.fullmatch(r"[a-zA-Z0-9](?:[a-zA-Z0-9.-]*[a-zA-Z0-9])?", hostname):
        raise ValueError("Use a DNS hostname, without scheme, path or port")
    if not 1 <= port <= 65535:
        raise ValueError("Invalid public port")
    runtime = target / "runtime"
    if runtime.exists():
        raise ValueError("runtime already exists; refusing to replace application keys or configuration")
    openssl("x509", "-in", cert, "-checkhost", hostname)
    # openssl checkhost can exit zero on a mismatch; inspect the actual result.
    if b"does match certificate" not in openssl("x509", "-in", cert, "-checkhost", hostname):
        raise ValueError("Receiver certificate hostname mismatch")
    openssl("x509", "-in", cert, "-checkend", "86400")
    if openssl("x509", "-in", cert, "-pubkey", "-noout").strip() != openssl("pkey", "-in", key, "-pubout").strip():
        raise ValueError("Receiver certificate and private key do not match")
    if not token.read_text().strip():
        raise ValueError("Internal API token file is empty")
    old_mask = os.umask(0o077)
    try:
        for part in ("receiver", "command", "bridge", "teslamate", "public"):
            (runtime / part).mkdir(parents=True, exist_ok=False)
        for src, name in ((cert, "fullchain.pem"), (key, "privkey.pem")):
            shutil.copyfile(src, runtime / "receiver" / name)
        command = runtime / "command"
        openssl("ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", command / "application.pem")
        openssl("ec", "-in", command / "application.pem", "-pubout", "-out", runtime / "public" / "com.tesla.3p.public-key.pem")
        openssl("req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "365", "-subj", "/CN=fleet-command",
                "-addext", "subjectAltName=DNS:fleet-command", "-addext", "basicConstraints=critical,CA:TRUE",
                "-addext", "extendedKeyUsage=serverAuth", "-keyout", command / "proxy-key.pem", "-out", command / "proxy-cert.pem")
        shutil.copyfile(command / "proxy-cert.pem", runtime / "teslamate" / "proxy-ca.pem")
        server = json.loads((ROOT / "deploy/fleet/server.json.example").read_text())
        server["port"] = 8443
        server["records"]["errors"] = ["kafka"]
        write_json(runtime / "receiver/server.json", server)
        write_json(runtime / "bridge/consumer.json", json.loads((ROOT / "deploy/fleet/consumer.json.example").read_text()))
        write_json(runtime / "bridge/routes.json", {})
        shutil.copyfile(token, runtime / "bridge/internal_api_token")
        vehicle = json.loads((ROOT / "deploy/fleet/vehicle-config.json.example").read_text())
        vehicle.update(hostname=hostname, port=port, ca=cert.read_text())
        write_json(runtime / "teslamate/vehicle-config.json", vehicle)
        # This directory contains only certificates and configuration, no private keys.
        (runtime / "teslamate").chmod(0o755)
        for file in (runtime / "teslamate").iterdir():
            file.chmod(0o644)
        (target / ".env").write_text(f"FLEET_UID={os.getuid()}\nFLEET_GID={os.getgid()}\nFLEET_TELEMETRY_PORT={port}\n")
    finally:
        os.umask(old_mask)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--cert", required=True, type=Path, help="PEM server + intermediate + root chain")
    parser.add_argument("--key", required=True, type=Path)
    parser.add_argument("--internal-token-file", required=True, type=Path)
    parser.add_argument("--port", type=int, default=443)
    args = parser.parse_args()
    initialize(ROOT / "deploy/fleet", args.hostname, args.cert, args.key, args.internal_token_file, args.port)
    print("Created deploy/fleet/runtime. Publish the application public key, mount runtime/teslamate into TeslaMate, then start Compose. See docs/fleet-account-test.md.")


if __name__ == "__main__":
    main()
