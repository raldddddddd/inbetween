import importlib.util
import io
import json
import sqlite3
import tempfile
import unittest
from unittest import mock
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("fallback_lifecycle_probe.py")
SPEC = importlib.util.spec_from_file_location("fallback_lifecycle_probe", MODULE_PATH)
probe = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(probe)


class FallbackLifecycleProbeTests(unittest.TestCase):
    def test_hook_sanitizer_excludes_content_fields(self):
        record = probe.sanitize_hook_event({
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "last_assistant_message": "secret response",
            "prompt": "secret prompt",
            "transcript_path": "/secret/transcript",
            "tool_input": {"secret": "source code"},
            "tool_name": "Bash",
            "reason": "secret reason",
        }, observed_at=10.0)

        self.assertEqual(record["hook_event_name"], "Stop")
        self.assertEqual(record["session_id"], "session-1")
        self.assertNotIn("last_assistant_message", record)
        self.assertNotIn("prompt", record)
        self.assertNotIn("transcript_path", record)
        self.assertNotIn("tool_input", record)
        self.assertNotIn("tool_name", record)
        self.assertNotIn("reason", record)
        self.assertNotIn("secret", json.dumps(record))

    def test_hook_handler_returns_only_inert_stop_json(self):
        payload = json.dumps({
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "last_assistant_message": "private",
        })
        with tempfile.TemporaryDirectory() as directory:
            log_path = Path(directory) / "events.jsonl"
            output = io.StringIO()
            with mock.patch("sys.stdin", io.StringIO(payload)), mock.patch("sys.stdout", output):
                result = probe.run_hook(log_path, None)
            record = json.loads(log_path.read_text())

        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), "{}")
        self.assertEqual(record["hook_event_name"], "Stop")
        self.assertNotIn("last_assistant_message", record)

    def test_hook_delivers_sanitized_unix_datagram(self):
        payload = json.dumps({
            "hook_event_name": "UserPromptSubmit",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "prompt": "private",
        })
        socket_path = Path("/tmp/inbetween-test.sock")
        client = mock.Mock()
        with mock.patch("sys.stdin", io.StringIO(payload)), mock.patch(
            "socket.socket", return_value=client
        ):
            result = probe.run_hook(None, socket_path)
        sent_payload, sent_path = client.sendto.call_args.args
        record = json.loads(sent_payload)

        self.assertEqual(result, 0)
        self.assertEqual(sent_path, str(socket_path))
        client.close.assert_called_once_with()
        self.assertEqual(record["hook_event_name"], "UserPromptSubmit")
        self.assertEqual(record["turn_id"], "turn-1")
        self.assertIsInstance(record["hookInvokedAt"], float)
        self.assertIsInstance(record["hookInvokedMonotonicNanoseconds"], int)
        self.assertIsInstance(record["bridgeSentAt"], float)
        self.assertIsInstance(record["bridgeSentMonotonicNanoseconds"], int)
        self.assertNotIn("prompt", record)

    def test_stop_latency_record_contains_only_safe_correlation_metadata(self):
        record = {
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "prompt": "private",
        }

        timing = probe.latency_record("hook_invoked", record, 10.0, 20)

        self.assertEqual(timing, {
            "stage": "hook_invoked",
            "wallTime": 10.0,
            "monotonicNanoseconds": 20,
            "sessionID": "session-1",
            "turnID": "turn-1",
        })
        self.assertNotIn("private", json.dumps(timing))

    def test_stop_hook_records_invocation_and_datagram_send_timing(self):
        payload = json.dumps({
            "hook_event_name": "Stop",
            "session_id": "session-1",
            "turn_id": "turn-1",
            "prompt": "private",
        })
        client = mock.Mock()
        with tempfile.TemporaryDirectory() as directory:
            latency_path = Path(directory) / "latency.jsonl"
            with mock.patch("sys.stdin", io.StringIO(payload)), mock.patch(
                "sys.stdout", io.StringIO()
            ), mock.patch("socket.socket", return_value=client), mock.patch.object(
                probe, "DEFAULT_LATENCY_LOG_PATH", latency_path
            ), mock.patch.object(
                probe.time, "time", side_effect=[10.0, 10.001]
            ), mock.patch.object(
                probe.time, "monotonic_ns", side_effect=[20, 30]
            ):
                result = probe.run_hook(None, Path("/tmp/test.sock"))
            records = [json.loads(line) for line in latency_path.read_text().splitlines()]

        self.assertEqual(result, 0)
        self.assertEqual([record["stage"] for record in records], [
            "hook_invoked", "bridge_datagram_sent"
        ])
        self.assertEqual(records[0]["monotonicNanoseconds"], 20)
        self.assertEqual(records[1]["monotonicNanoseconds"], 30)
        self.assertNotIn("private", json.dumps(records))

    def test_in_progress_is_ambiguous_active_not_working(self):
        self.assertEqual(probe.classify_turn({"rawStatus": "inProgress"}), "activeUnknown")

    def test_completion_requires_same_turn_transition(self):
        active = {"turnId": "turn-1", "rawStatus": "inProgress"}
        completed = {"turnId": "turn-1", "rawStatus": "completed"}
        other = {"turnId": "turn-2", "rawStatus": "completed"}

        self.assertTrue(probe.is_completion(active, completed))
        self.assertFalse(probe.is_completion(active, other))

    def test_sql_query_selects_only_lifecycle_columns(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "history.sqlite"
            connection = sqlite3.connect(path)
            connection.execute("""
                CREATE TABLE thread_turns (
                    thread_id TEXT, turn_id TEXT, rollout_ordinal INTEGER,
                    status TEXT, error_json TEXT, started_at INTEGER,
                    completed_at INTEGER, duration_ms INTEGER, secret TEXT
                )
            """)
            connection.execute(
                "INSERT INTO thread_turns VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                ("thread-1", "turn-1", 1, "inProgress", "private", 12, None, None, "source"),
            )
            connection.commit()

            turn = probe.read_latest_turn(connection, "thread-1")
            connection.close()

        self.assertEqual(turn, {
            "turnId": "turn-1",
            "rawStatus": "inProgress",
            "startedAt": 12,
            "completedAt": None,
            "durationMs": None,
        })


if __name__ == "__main__":
    unittest.main()
