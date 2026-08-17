#!/bin/sh
# Local calendar store for OpenClaw agents (workspace/calendar/events.json).
# Usage:
#   calendar.sh list
#   calendar.sh upcoming [hours]
#   calendar.sh add --title T --at ISO [--duration MIN] [--remind 1440,60,10] [--notes TEXT] [--channel CH] [--to ID]
#   calendar.sh get ID
#   calendar.sh ack ID
#   calendar.sh cancel ID
#   calendar.sh set-jobs ID id1,id2
set -eu

ROOT="${OPENCLAW_HOME:-/home/node/.openclaw}"
STORE="${ROOT}/workspace/calendar/events.json"
CMD="${1:-list}"
[ "$#" -gt 0 ] && shift

python3 - "$CMD" "$STORE" "$@" <<'PY'
import json, os, sys, uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

cmd = sys.argv[1]
store = Path(sys.argv[2])
args = sys.argv[3:]

def now():
    return datetime.now(timezone.utc)

def parse_iso(value):
    raw = value.strip()
    if raw.endswith("Z"):
        raw = raw[:-1] + "+00:00"
    dt = datetime.fromisoformat(raw)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)

def load():
    if not store.is_file():
        return {"timezone": os.environ.get("IDENTYCLAW_CALENDAR_TZ", "UTC"), "events": []}
    return json.loads(store.read_text(encoding="utf-8"))

def save(data):
    store.parent.mkdir(parents=True, exist_ok=True)
    store.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    try:
        store.chmod(0o644)
    except OSError:
        pass

def parse_flags(argv):
    out = {}
    i = 0
    while i < len(argv):
        key = argv[i]
        if not key.startswith("--") or i + 1 >= len(argv):
            print(
                "usage: calendar.sh add --title T --at ISO [--duration MIN] [--remind 1440,60,10]",
                file=sys.stderr,
            )
            sys.exit(2)
        out[key[2:].replace("-", "_")] = argv[i + 1]
        i += 2
    return out

def dump(obj):
    print(json.dumps(obj, indent=2))

data = load()
events = data.setdefault("events", [])

if cmd == "list":
    active = [e for e in events if e.get("status") == "active"]
    dump({"timezone": data.get("timezone", "UTC"), "count": len(active), "events": active})
    sys.exit(0)

if cmd == "upcoming":
    hours = int(args[0] if args else 24)
    end = now() + timedelta(hours=hours)
    upcoming = []
    for event in events:
        if event.get("status") != "active":
            continue
        try:
            start = parse_iso(event["start"])
        except (KeyError, ValueError):
            continue
        if now() - timedelta(minutes=15) <= start <= end:
            upcoming.append(event)
    upcoming.sort(key=lambda e: e.get("start", ""))
    dump({"hours": hours, "count": len(upcoming), "events": upcoming})
    sys.exit(0)

if cmd == "add":
    flags = parse_flags(args)
    title = (flags.get("title") or "").strip()
    at = (flags.get("at") or "").strip()
    if not title or not at:
        print("calendar.sh add requires --title and --at", file=sys.stderr)
        sys.exit(2)
    start = parse_iso(at)
    remind_raw = flags.get("remind") or "1440,60,10"
    remind = []
    for part in remind_raw.split(","):
        part = part.strip()
        if not part:
            continue
        remind.append(int(part))
    event = {
        "id": "evt_" + uuid.uuid4().hex[:12],
        "title": title,
        "start": start.isoformat().replace("+00:00", "Z"),
        "durationMinutes": int(flags.get("duration") or 60),
        "notes": flags.get("notes") or "",
        "remindOffsetsMinutes": remind,
        "channel": flags.get("channel") or "",
        "to": flags.get("to") or "",
        "cronJobIds": [],
        "acked": False,
        "status": "active",
    }
    events.append(event)
    save(data)
    dump(event)
    sys.exit(0)

if cmd in {"get", "ack", "cancel", "set-jobs"}:
    if not args:
        print(f"calendar.sh {cmd} requires an event id", file=sys.stderr)
        sys.exit(2)
    event_id = args[0]
    event = next((e for e in events if e.get("id") == event_id), None)
    if event is None:
        print(json.dumps({"ok": False, "error": "not_found", "id": event_id}))
        sys.exit(1)
    if cmd == "get":
        dump(event)
        sys.exit(0)
    if cmd == "ack":
        event["acked"] = True
    elif cmd == "cancel":
        event["status"] = "cancelled"
    elif cmd == "set-jobs":
        jobs = args[1] if len(args) > 1 else ""
        event["cronJobIds"] = [j.strip() for j in jobs.split(",") if j.strip()]
    save(data)
    dump(event)
    sys.exit(0)

print(f"unknown command: {cmd}", file=sys.stderr)
sys.exit(2)
PY
