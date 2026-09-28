#!/usr/bin/env python3
"""Phase 0 metadata-only probes for Codex lifecycle feasibility.

The hook mode deliberately discards all prompt, transcript, message, document,
tool-input, and tool-output fields. The sqlite mode selects only turn lifecycle
columns from Codex's unsupported internal thread-history projection.
"""

from __future__ import annotations

import argparse
import json
import signal
import socket
import sqlite3
import sys
import time
from pathlib import Path
from typing import Any


TERMINAL_TURN_STATUSES = {"completed", "failed", "interrupted", "cancelled"}
ALLOWED_HOOK_FIELDS = {
    "hook_event_name",
    "permission_mode",
    "session_id",
    "stop_hook_active",
    "turn_id",
}
DEFAULT_LATENCY_LOG_PATH = Path("/tmp/inbetween-stop-latency.jsonl")


def append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")
    path.chmod(0o600)


def sanitize_hook_event(payload: dict[str, Any], observed_at: float | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "observedAt": observed_at if observed_at is not None else time.time(),
    }
    for key in ALLOWED_HOOK_FIELDS:
        value = payload.get(key)
        if isinstance(value, (str, bool, int, float)) or value is None:
            if value is not None:
                record[key] = value
    return record


def read_latest_turn(connection: sqlite3.Connection, thread_id: str) -> dict[str, Any] | None:
    row = connection.execute(
        """
        SELECT turn_id, status, started_at, completed_at, duration_ms
        FROM thread_turns
        WHERE thread_id = ?
        ORDER BY rollout_ordinal DESC
        LIMIT 1
        """,
        (thread_id,),
    ).fetchone()
    if row is None:
        return None
    return {
        "turnId": row[0],
        "rawStatus": row[1],
        "startedAt": row[2],
        "completedAt": row[3],
        "durationMs": row[4],
    }


def classify_turn(turn: dict[str, Any] | None) -> str:
    if turn is None:
        return "unknown"
    status = turn.get("rawStatus")
    if status == "inProgress":
        # The projection does not expose whether an active turn is running or
        # blocked on the user. Calling this "working" would guess.
        return "activeUnknown"
    if status in TERMINAL_TURN_STATUSES:
        return "idle"
    return "unknown"


def sqlite_record(turn: dict[str, Any] | None, observed_at: float | None = None) -> dict[str, Any]:
    record: dict[str, Any] = {
        "observedAt": observed_at if observed_at is not None else time.time(),
        "source": "unsupportedThreadHistorySQLite",
        "state": classify_turn(turn),
    }
    if turn:
        record.update(turn)
    return record


def is_completion(previous: dict[str, Any] | None, current: dict[str, Any] | None) -> bool:
    return bool(
        previous
        and current
        and previous.get("turnId") == current.get("turnId")
        and previous.get("rawStatus") == "inProgress"
        and current.get("rawStatus") in TERMINAL_TURN_STATUSES
    )


def send_datagram(socket_path: Path, record: dict[str, Any]) -> None:
    payload = json.dumps(record, sort_keys=True, separators=(",", ":")).encode("utf-8")
    client = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    try:
        client.sendto(payload, str(socket_path))
    finally:
        client.close()


def latency_record(
    stage: str,
    lifecycle_record: dict[str, Any],
    wall_time: float,
    monotonic_ns: int,
) -> dict[str, Any]:
    return {
        "stage": stage,
        "wallTime": wall_time,
        "monotonicNanoseconds": monotonic_ns,
        "sessionID": lifecycle_record.get("session_id"),
        "turnID": lifecycle_record.get("turn_id"),
    }


def run_hook(log_path: Path | None, socket_path: Path | None) -> int:
    hook_invoked_wall = time.time()
    hook_invoked_monotonic_ns = time.monotonic_ns()
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict):
        return 2
    record = sanitize_hook_event(payload, observed_at=hook_invoked_wall)
    is_stop = payload.get("hook_event_name") == "Stop"
    if log_path is not None:
        append_jsonl(log_path, record)
    if socket_path is not None:
        bridge_sent_wall = time.time()
        bridge_sent_monotonic_ns = time.monotonic_ns()
        record["hookInvokedAt"] = hook_invoked_wall
        record["hookInvokedMonotonicNanoseconds"] = hook_invoked_monotonic_ns
        record["bridgeSentAt"] = bridge_sent_wall
        record["bridgeSentMonotonicNanoseconds"] = bridge_sent_monotonic_ns
        send_succeeded = False
        try:
            send_datagram(socket_path, record)
            send_succeeded = True
        except OSError:
            # Inbetween may not be running. Lifecycle observation must never
            # alter or fail the Codex turn.
            pass
        if is_stop:
            append_jsonl(
                DEFAULT_LATENCY_LOG_PATH,
                latency_record(
                    "hook_invoked",
                    record,
                    hook_invoked_wall,
                    hook_invoked_monotonic_ns,
                ),
            )
            append_jsonl(
                DEFAULT_LATENCY_LOG_PATH,
                latency_record(
                    "bridge_datagram_sent" if send_succeeded else "bridge_datagram_failed",
                    record,
                    bridge_sent_wall,
                    bridge_sent_monotonic_ns,
                ),
            )
    # Stop specifically expects JSON on successful exit. An empty object is a
    # valid no-op: it contains no decision, context, warning, or behavior change.
    if is_stop:
        sys.stdout.write("{}")
    return 0


def run_sqlite(db_path: Path, thread_id: str, log_path: Path, interval: float, once: bool) -> int:
    uri = f"file:{db_path}?mode=ro"
    connection = sqlite3.connect(uri, uri=True, timeout=1.0)
    previous: dict[str, Any] | None = None
    previous_signature: tuple[Any, ...] | None = None
    running = True

    def stop(_signum: int, _frame: Any) -> None:
        nonlocal running
        running = False

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    while running:
        try:
            current = read_latest_turn(connection, thread_id)
            signature = tuple((current or {}).get(key) for key in (
                "turnId", "rawStatus", "startedAt", "completedAt", "durationMs"
            ))
            if signature != previous_signature:
                record = sqlite_record(current)
                if is_completion(previous, current):
                    record["transition"] = "completion"
                append_jsonl(log_path, record)
                previous = current
                previous_signature = signature
        except sqlite3.Error as error:
            append_jsonl(log_path, {
                "observedAt": time.time(),
                "source": "unsupportedThreadHistorySQLite",
                "state": "unavailable",
                "errorType": type(error).__name__,
            })
        if once:
            break
        time.sleep(interval)
    connection.close()
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    hook = subparsers.add_parser("hook")
    hook.add_argument("--log", type=Path)
    hook.add_argument("--socket", type=Path)

    sqlite = subparsers.add_parser("sqlite")
    sqlite.add_argument("--db", type=Path, required=True)
    sqlite.add_argument("--thread", required=True)
    sqlite.add_argument("--log", type=Path, required=True)
    sqlite.add_argument("--interval", type=float, default=0.1)
    sqlite.add_argument("--once", action="store_true")
    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    if arguments.command == "hook":
        if arguments.log is None and arguments.socket is None:
            raise SystemExit("hook requires --socket and/or --log")
        return run_hook(arguments.log, arguments.socket)
    return run_sqlite(
        arguments.db,
        arguments.thread,
        arguments.log,
        arguments.interval,
        arguments.once,
    )


if __name__ == "__main__":
    raise SystemExit(main())
