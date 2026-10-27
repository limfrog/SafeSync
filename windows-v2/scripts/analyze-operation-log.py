"""Summarize SafeSync JSONL locally; standard library only, no network access.
Usage: python analyze-operation-log.py PATH_TO_OPERATIONS_FOLDER
"""
import collections
import datetime
import json
import hashlib
import pathlib
import statistics
import sys

def analyze(folder):
    runs = collections.defaultdict(lambda: {"phases": collections.defaultdict(list), "initialPhases": collections.defaultdict(list), "http": collections.defaultdict(list), "events": collections.Counter(), "errorEvents": 0})
    malformed = dropped = 0
    seen = set()
    for path in sorted(pathlib.Path(folder).glob("*.jsonl")):
        with path.open(encoding="utf-8-sig") as stream:
            for line in stream:
                try:
                    row = json.loads(line)
                except ValueError:
                    malformed += 1
                    continue
                fingerprint = hashlib.sha256(json.dumps(row, sort_keys=True).encode()).digest()
                if fingerprint in seen:
                    continue
                seen.add(fingerprint)
                dropped += row.get("Count", 0) if row.get("Event") == "log.dropped" else 0
                key = (row.get("Session"), row.get("Run") or "startup")
                run = runs[key]
                event, operation = row.get("Event"), row.get("Operation", "unknown")
                run["events"][event] += 1
                if event == "run.start":
                    run["start"] = row.get("Utc")
                    run["plan"] = row.get("Detail")
                if event == "run.end":
                    run["elapsedMs"] = row.get("Ms")
                    run["outcome"] = row.get("Detail")
                if event == "run.result":
                    run["result"] = row.get("Detail")
                if event == "span.end" and operation.startswith(("prepare.", "application.", "state.", "storage.")):
                    run["phases"][operation].append(row.get("Ms", 0))
                if event == "prepare.phase":
                    run["initialPhases"][operation].append(row.get("Ms", 0))
                if event == "http.end":
                    run["http"][operation].append((row.get("Ms", 0), row.get("Status")))
                if event in ("file.error", "run.error"):
                    run["errorEvents"] += 1
                if event == "span.start" and operation == "file.upload" and "firstUpload" not in run:
                    run["firstUpload"] = row.get("Utc")
                if event in ("prepare.ready", "transfer.first"):
                    run[event] = row.get("Ms")
    output = {"malformedOrPartialLines": malformed, "droppedEvents": dropped, "runs": []}
    for (session, identifier), run in runs.items():
        phases = [{"phase": phase, "count": len(values), "sumMs": round(sum(values), 2), "maxMs": round(max(values), 2)} for phase, values in run.pop("phases").items()]
        initial = [{"phase": phase, "count": len(values), "sumMs": round(sum(values), 2), "maxMs": round(max(values), 2)} for phase, values in run.pop("initialPhases").items()]
        http = [{"operation": operation, "count": len(values), "sumMs": round(sum(v[0] for v in values), 2), "medianMs": round(statistics.median(v[0] for v in values), 2), "statuses": dict(collections.Counter(str(v[1]) for v in values))} for operation, values in run.pop("http").items()]
        if run.get("start") and run.get("firstUpload"):
            try:
                parse = lambda s: datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))
                run["untilFirstUploadMs"] = round((parse(run["firstUpload"]) - parse(run["start"])).total_seconds() * 1000, 2)
            except ValueError:
                pass
        output["runs"].append({"session": session, "run": identifier, **run, "initialPhases": sorted(initial, key=lambda p: -p["sumMs"]), "phases": sorted(phases, key=lambda p: -p["sumMs"]), "http": sorted(http, key=lambda p: -p["sumMs"])})
    return output

if __name__ == "__main__":
    print(json.dumps(analyze(sys.argv[1]), ensure_ascii=False, indent=2))
