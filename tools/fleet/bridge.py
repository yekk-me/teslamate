#!/usr/bin/env python3
"""Official Fleet Telemetry decoded Kafka records -> tenant durable inbox.

Offsets are committed synchronously only after every authorized destination
confirms a durable insert or duplicate. Supervisor restarts retry failures.
"""
import json
import os
import sys
from pathlib import Path
from urllib.parse import quote, urlsplit
from urllib.request import Request, build_opener, HTTPRedirectHandler


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def deliver(consumer, message, routes, post):
    if message.error():
        raise RuntimeError("Kafka read failed; offset retained")
    try:
        payload = json.loads(message.value())
        vin = message.key().decode("utf-8")
        if not isinstance(payload, dict) or payload.get("vin") != vin:
            raise ValueError()
        tenants = routes[vin]
        # Explicit control-plane revocation stops recording without blocking other VINs.
        # Unknown VINs remain an error; an empty/malformed assignment is never a revocation.
        if tenants == {"disabled": True}:
            tenants = []
        elif not isinstance(tenants, list) or not tenants:
            raise ValueError()
        if any(not isinstance(t, str) or not t for t in tenants):
            raise ValueError()
    except (ValueError, KeyError, TypeError, AttributeError):
        raise RuntimeError("Invalid record or missing VIN route; offset retained") from None
    for tenant in dict.fromkeys(tenants):
        result = post(tenant, payload)
        if not isinstance(result, dict) or result.get("status") not in ("stored", "duplicate"):
            raise RuntimeError("Inbox did not acknowledge durable storage; offset retained")
    partitions = consumer.commit(message=message, asynchronous=False)
    if partitions and any(p.error for p in partitions):
        raise RuntimeError("Offset commit failed; record may be redelivered")


def http_sender(base_url, token):
    uri = urlsplit(base_url)
    if uri.scheme not in ("http", "https") or not uri.hostname or uri.username or uri.password:
        raise ValueError("Invalid TESLAMATE_INTERNAL_URL")
    if not token:
        raise ValueError("Internal API token is required")
    opener = build_opener(NoRedirect())

    def post(tenant, payload):
        url = base_url.rstrip("/") + "/api/internal/tenants/" + quote(tenant, safe="") + "/fleet/events"
        request = Request(url, data=json.dumps({"record": payload}).encode(), method="POST",
                          headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        # urllib verifies server certificates. Redirects are deliberately disabled.
        with opener.open(request, timeout=30) as response:
            if response.status != 200:
                raise RuntimeError("Inbox HTTP failure")
            return json.load(response)
    return post


def main():
    from confluent_kafka import Consumer
    config = json.loads(Path(os.environ["KAFKA_CONSUMER_CONFIG"]).read_text())
    config.update({"enable.auto.commit": False, "enable.auto.offset.store": False,
                   "auto.offset.reset": "earliest"})
    route_path = Path(os.environ["FLEET_VIN_ROUTES"])
    token = Path(os.environ["TESLAMATE_INTERNAL_API_TOKEN_FILE"]).read_text().strip()
    post = http_sender(os.environ["TESLAMATE_INTERNAL_URL"], token)
    consumer = Consumer(config)
    consumer.subscribe([os.environ.get("FLEET_KAFKA_TOPIC", "teslamate_V")])
    try:
        while True:
            message = consumer.poll(1.0)
            if message is not None:
                routes = json.loads(route_path.read_text())
                deliver(consumer, message, routes, post)
    finally:
        consumer.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except Exception:
        # Do not log request/response objects, tokens, vehicle locations or VINs.
        print("Fleet bridge stopped; uncommitted record retained. Check routing, inbox and Kafka health.", file=sys.stderr)
        sys.exit(1)
