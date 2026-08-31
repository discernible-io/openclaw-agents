#!/usr/bin/env python3
"""Repair OpenClaw 2026.8+ session transcripts missing a v3 session header.

Channel /new can persist a reset-first transcript with no session header; runtime
then fails with "Persisted legacy session transcripts require doctor/import".
Prepends the required header and shifts existing events (idempotent per session).
"""
from __future__ import annotations

import json
import sqlite3
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _has_v3_header(events: list[dict]) -> bool:
    return any(
        ev.get("type") == "session" and int(ev.get("version", 1)) >= 3 for ev in events
    )


def _repair_session(db: sqlite3.Connection, session_id: str, cwd: str) -> bool:
    rows = db.execute(
        "SELECT seq, event_json, created_at FROM transcript_events "
        "WHERE session_id=? ORDER BY seq",
        (session_id,),
    ).fetchall()
    if not rows:
        return False
    events = [json.loads(row[1]) for row in rows]
    if _has_v3_header(events):
        return False

    first_ts = events[0].get("timestamp") or _now_iso()
    created_at = rows[0][2] if rows[0][2] is not None else int(time.time() * 1000)
    header = {
        "type": "session",
        "version": 3,
        "id": session_id,
        "timestamp": first_ts,
        "cwd": cwd,
    }

    db.execute(
        "UPDATE transcript_events SET seq = -1 - seq WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE transcript_events SET seq = (-1 - seq) + 1 WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "INSERT INTO transcript_events (session_id, seq, event_json, created_at) "
        "VALUES (?, 0, ?, ?)",
        (session_id, json.dumps(header, separators=(",", ":")), created_at),
    )

    db.execute(
        "UPDATE transcript_event_identities SET seq = -1 - seq WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE transcript_event_identities SET seq = (-1 - seq) + 1 WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE session_transcript_active_events SET event_seq = -1 - event_seq "
        "WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE session_transcript_active_events SET event_seq = (-1 - event_seq) + 1 "
        "WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE trajectory_runtime_events SET seq = -1 - seq WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE trajectory_runtime_events SET seq = (-1 - seq) + 1 WHERE session_id=?",
        (session_id,),
    )
    db.execute(
        "UPDATE session_transcript_index_state SET needs_rebuild=1 WHERE session_id=?",
        (session_id,),
    )
    return True


def repair_sqlite(path: Path, cwd: str = "/home/node/.openclaw/workspace") -> int:
    if not path.is_file():
        return 0
    db = sqlite3.connect(str(path))
    try:
        db.execute("PRAGMA busy_timeout=5000")
        session_ids = [
            row[0]
            for row in db.execute("SELECT DISTINCT session_id FROM transcript_events")
        ]
        repaired = 0
        for session_id in session_ids:
            if _repair_session(db, session_id, cwd):
                repaired += 1
                print(f"repaired session header: {session_id}", file=sys.stderr)
        if repaired:
            db.commit()
        return repaired
    finally:
        db.close()


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/home/node/.openclaw")
    sqlite_path = root / "agents/main/agent/openclaw-agent.sqlite"
    cwd = str(root / "workspace")
    repair_sqlite(sqlite_path, cwd=cwd)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
