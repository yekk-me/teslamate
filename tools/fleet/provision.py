#!/usr/bin/env python3
"""China-only Fleet registration and signed telemetry setup. Never prints tokens."""
import argparse
import json
import os
import ssl
import sys
from pathlib import Path
from urllib.parse import urlencode, quote, urlsplit
from urllib.request import Request, build_opener, HTTPSHandler
from bridge import NoRedirect

API = "https://fleet-api.prd.cn.vn.cloud.tesla.cn"
TOKEN_URL = "https://auth.tesla.cn/oauth2/v3/token"


def request(url, data=None, token=None, form=False, ca=None):
    headers = {}
    if token:
        headers["Authorization"] = "Bearer " + token
    if data is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
        data = (urlencode(data) if form else json.dumps(data)).encode()
    opener = build_opener(NoRedirect(), HTTPSHandler(context=ssl.create_default_context(cafile=ca)))
    with opener.open(Request(url, data=data, headers=headers), timeout=60) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("register").add_argument("domain")
    config = sub.add_parser("configure")
    config.add_argument("vin")
    config.add_argument("config_file")
    sub.add_parser("status").add_argument("vin")
    args = parser.parse_args()
    if args.command == "register":
        if ":" in args.domain or "/" in args.domain or not args.domain:
            parser.error("domain must be the registered hostname only")
        token = request(TOKEN_URL, {"grant_type": "client_credentials",
            "client_id": os.environ["TESLA_FLEET_CLIENT_ID"],
            "client_secret": os.environ["TESLA_FLEET_CLIENT_SECRET"],
            "audience": API, "scope": "openid vehicle_device_data vehicle_location"}, form=True)["access_token"]
        result = request(API + "/api/1/partner_accounts", {"domain": args.domain}, token)
    else:
        token = Path(os.environ["TESLA_FLEET_ACCESS_TOKEN_FILE"]).read_text().strip()
        if args.command == "configure":
            proxy = os.environ["TESLA_FLEET_COMMAND_PROXY"].rstrip("/")
            uri = urlsplit(proxy)
            if uri.scheme != "https" or not uri.hostname or uri.username or uri.password:
                parser.error("command proxy must be a trusted HTTPS URL")
            config = json.loads(Path(args.config_file).read_text())
            if "REPLACE" in json.dumps(config):
                parser.error("replace all example configuration placeholders first")
            if not config.get("hostname") or not config.get("ca") or not config.get("fields"):
                parser.error("hostname, full certificate chain ca and fields are required")
            result = request(proxy + "/api/1/vehicles/fleet_telemetry_config",
                {"vins": [args.vin], "config": config}, token,
                ca=os.environ.get("TESLA_FLEET_PROXY_CA_FILE"))
            if any(result.get("response", {}).get("skipped_vehicles", {}).values()):
                print(json.dumps(result, ensure_ascii=False, indent=2))
                return 2
        else:
            root = API + "/api/1/vehicles/" + quote(args.vin, safe="")
            result = {"config": request(root + "/fleet_telemetry_config", token=token),
                      "errors": request(root + "/fleet_telemetry_errors", token=token)}
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:
        print("Fleet setup failed. Check China app credentials, scopes, certificates and virtual-key pairing.", file=sys.stderr)
        sys.exit(1)
