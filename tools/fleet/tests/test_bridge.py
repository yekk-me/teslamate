import sys
import unittest
from pathlib import Path
from unittest.mock import Mock
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bridge import deliver


class DeliveryTest(unittest.TestCase):
    def setUp(self):
        self.consumer = Mock()
        self.consumer.commit.return_value = []
        self.msg = Mock()
        self.msg.error.return_value = None
        self.msg.key.return_value = b"LRW00000000000001"
        self.msg.value.return_value = b'{"vin":"LRW00000000000001","data":[]}'
        self.routes = {"LRW00000000000001": ["tenant-a", "tenant-b"]}

    def test_fanout_commits_only_after_all_destinations(self):
        post = Mock(side_effect=[{"status": "stored"}, {"status": "duplicate"}])
        deliver(self.consumer, self.msg, self.routes, post)
        self.assertEqual([c.args[0] for c in post.call_args_list], ["tenant-a", "tenant-b"])
        self.consumer.commit.assert_called_once_with(message=self.msg, asynchronous=False)

    def test_partial_failure_preserves_offset_for_idempotent_retry(self):
        post = Mock(side_effect=[{"status": "stored"}, TimeoutError()])
        with self.assertRaises(TimeoutError):
            deliver(self.consumer, self.msg, self.routes, post)
        self.consumer.commit.assert_not_called()

    def test_cross_vin_payload_cannot_choose_tenant(self):
        self.msg.value.return_value = b'{"vin":"another-car"}'
        post = Mock()
        with self.assertRaises(RuntimeError):
            deliver(self.consumer, self.msg, self.routes, post)
        post.assert_not_called()
        self.consumer.commit.assert_not_called()

    def test_unknown_vin_is_not_silently_skipped(self):
        with self.assertRaises(RuntimeError):
            deliver(self.consumer, self.msg, {}, Mock())
        self.consumer.commit.assert_not_called()

    def test_nondurable_http_success_is_rejected(self):
        with self.assertRaises(RuntimeError):
            deliver(self.consumer, self.msg, self.routes, Mock(return_value={"status": "queued"}))
        self.consumer.commit.assert_not_called()

    def test_explicit_revocation_does_not_block_other_vehicles(self):
        post = Mock()
        deliver(self.consumer, self.msg, {"LRW00000000000001": {"disabled": True}}, post)
        post.assert_not_called()
        self.consumer.commit.assert_called_once()

    def test_empty_route_is_not_an_implicit_revocation(self):
        with self.assertRaises(RuntimeError):
            deliver(self.consumer, self.msg, {"LRW00000000000001": []}, Mock())
        self.consumer.commit.assert_not_called()
