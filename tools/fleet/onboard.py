#!/usr/bin/env python3
"""Operator account test: official OAuth, tenant assignment, signed telemetry and status."""
import argparse
import getpass
import hmac
import json
import os
import sys
import tempfile
import time
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit
from urllib.request import Request, build_opener
from bridge import NoRedirect

ROOT = Path(__file__).resolve().parents[2]


def callback_credentials(authorization_url, callback):
    auth = urlsplit(authorization_url)
    if auth.scheme != "https" or auth.netloc != "auth.tesla.cn" or auth.path != "/oauth2/v3/authorize":
        raise ValueError("Unexpected authorization server")
    params = parse_qs(auth.query, strict_parsing=True)
    expected = urlsplit(params["redirect_uri"][0])
    actual = urlsplit(callback.strip())
    if (actual.scheme, actual.netloc, actual.path) != (expected.scheme, expected.netloc, expected.path) or actual.fragment:
        raise ValueError("Callback URL does not match the registered redirect URI")
    query = parse_qs(actual.query, strict_parsing=True)
    for key, values in parse_qs(expected.query).items():
        if query.get(key) != values:
            raise ValueError("Callback query does not match registered redirect URI")
    if "error" in query:
        raise ValueError("Tesla authorization was declined; begin again")
    if len(query.get("state", [])) != 1 or len(query.get("code", [])) != 1:
        raise ValueError("Missing or ambiguous OAuth code/state")
    if not hmac.compare_digest(params["state"][0], query["state"][0]):
        raise ValueError("OAuth state mismatch; callback belongs to another authorization")
    return {"code": query["code"][0], "state": query["state"][0]}


def atomic_json(path, value):
    path = Path(path)
    existing = path.stat() if path.exists() else None
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=".fleet-")
    try:
        if existing:
            os.fchmod(fd, existing.st_mode & 0o777)
            if os.geteuid() == 0:
                os.fchown(fd, existing.st_uid, existing.st_gid)
        with os.fdopen(fd, "w") as out:
            json.dump(value, out, indent=2)
            out.write("\n")
            out.flush()
            os.fsync(out.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def assign(directory, routes_path, tenant, vehicle):
    if directory:
        content = json.loads(directory.read_text())
        matches = [t for t in content["tenants"] if t["id"] == tenant]
        if len(matches) != 1:
            raise ValueError("Tenant must already exist exactly once in the directory")
        rows = matches[0].get("vehicles", [])
        matches[0]["vehicles"] = [v for v in rows if v.get("vin") != vehicle["vin"]] + [vehicle]
        atomic_json(directory, content)
    routes = json.loads(routes_path.read_text())
    routes[vehicle["vin"]] = list(dict.fromkeys(routes.get(vehicle["vin"], []) + [tenant]))
    atomic_json(routes_path, routes)


def api(base, token, path, body=None):
    uri = urlsplit(base)
    if uri.scheme not in ("http", "https") or not uri.hostname or uri.username or uri.password:
        raise ValueError("Invalid internal API URL")
    headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
    req = Request(base.rstrip("/") + path, headers=headers,
                  data=None if body is None else json.dumps(body).encode())
    with build_opener(NoRedirect()).open(req, timeout=90) as result:
        return json.load(result)["data"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["authorize", "configure", "status"])
    parser.add_argument("--tenant", required=True)
    parser.add_argument("--vin", required=True, help="One vehicle to enable, not every car on the account")
    parser.add_argument("--base-url", default=os.getenv("TESLAMATE_INTERNAL_URL", "http://127.0.0.1:4000"))
    parser.add_argument("--token-file", type=Path, default=ROOT / "deploy/fleet/runtime/bridge/internal_api_token")
    parser.add_argument("--directory-file", type=Path, help="Only for FileDirectory test tenants; mount its directory, not the individual file")
    parser.add_argument("--routes-file", type=Path, default=ROOT / "deploy/fleet/runtime/bridge/routes.json")
    args = parser.parse_args()
    token = args.token_file.read_text().strip()
    if not token:
        raise ValueError("Empty internal API token")
    root = "/api/internal/tenants/" + quote(args.tenant, safe="")
    endpoint = root + "/fleet/vehicles/" + quote(args.vin, safe="") + "/telemetry"
    if args.command == "authorize":
        result = api(args.base_url, token, root + "/fleet/authorize", {})
        print("Open this official URL in your browser (valid for 10 minutes):\n" + result["authorization_url"])
        callback = getpass.getpass("Paste the complete callback URL (hidden): ")
        credentials = callback_credentials(result["authorization_url"], callback)
        result = api(args.base_url, token, root + "/authorize", credentials)
        matches = [v for v in result["vehicles"] if v.get("vin") == args.vin]
        if len(matches) != 1:
            raise ValueError("Selected VIN was not returned by this Tesla account")
        assign(args.directory_file, args.routes_file, args.tenant, matches[0])
        if not args.directory_file:
            output = ROOT / "deploy/fleet/runtime/vehicle-assignment.json"
            atomic_json(output, {"tenant_id": args.tenant, "vehicles": matches})
            print("Persist runtime/vehicle-assignment.json in your existing control plane before configuring.")
        print("Authorization stored encrypted. Wait for tenant sync, restart fleet-bridge to load routes, pair the application virtual key in Tesla App, then run configure.")
    elif args.command == "configure":
        api(args.base_url, token, endpoint, {})
        for _ in range(24):
            result = api(args.base_url, token, endpoint)
            if result.get("synced") is True:
                print("Vehicle reports synced=true. Run status and check telemetry event counts while the car is awake.")
                return 0
            time.sleep(5)
        print("Configuration submitted but not confirmed synced. Check virtual key, vehicle connectivity and status/errors.")
        return 2
    else:
        print(json.dumps({"configuration": api(args.base_url, token, endpoint),
                          "errors": api(args.base_url, token, endpoint + "/errors"),
                          "inbox": api(args.base_url, token, root + "/fleet/status")}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Exception, KeyboardInterrupt):
        print("Fleet onboarding failed. Check tenant readiness, registered callback, selected VIN and server configuration. No credentials were logged.", file=sys.stderr)
        sys.exit(1)
