import json
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import urlencode
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from onboard import callback_credentials, assign

class OnboardTest(unittest.TestCase):
    def setUp(self):
        self.auth = "https://auth.tesla.cn/oauth2/v3/authorize?" + urlencode({"redirect_uri":"https://app.example/fleet/callback", "state":"expected"})

    def test_callback_bound_to_state_and_registered_uri(self):
        good = "https://app.example/fleet/callback?code=secret-code&state=expected"
        self.assertEqual(callback_credentials(self.auth, good), {"code":"secret-code", "state":"expected"})
        for bad in (good.replace("expected", "wrong"), good.replace("app.example", "evil.example"), good + "&code=second", good + "&error=access_denied"):
            with self.assertRaises(ValueError):
                callback_credentials(self.auth, bad)

    def test_assignment_preserves_other_tenants_and_vehicles(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory, routes = Path(tmp)/"tenants.json", Path(tmp)/"routes.json"
            directory.write_text(json.dumps({"tenants":[{"id":"a", "vehicles":[{"vin":"old"}]}, {"id":"b", "vehicles":[]}]}))
            routes.write_text('{"new":["b"]}')
            for _ in range(2):
                assign(directory, routes, "a", {"id":"1", "vin":"new"})
            self.assertEqual(json.loads(routes.read_text()), {"new":["b", "a"]})
            tenants = json.loads(directory.read_text())["tenants"]
            self.assertEqual(len(tenants[0]["vehicles"]), 2)
            self.assertEqual(tenants[1]["vehicles"], [])
            with self.assertRaises(ValueError):
                assign(directory, routes, "unknown", {"vin":"new"})
