#!/usr/bin/env python3
"""Local Phase 0 ground truth recorder and conservative event metrics; stdlib only."""
import argparse
import hashlib
import json
import statistics
import time
from pathlib import Path

STATES = {"idle", "working", "needsUser", "finished", "unknown"}
SCENARIOS = [
    "text", "small-edit", "multi-edit", "shell", "build", "tests", "approval",
    "clarification", "resume", "failure", "cancellation", "compaction", "switch",
    "background", "minimized", "sleep-wake", "relaunch", "back-to-back",
    "quiet-long-task", "concurrent",
]


def read(path):
    with open(path) as stream:
        return [json.loads(line) for line in stream if line.strip()]


def analyze(truth, detector):
    runs = sorted({r["run"] for r in truth})
    totals = {state: {"truePositives": 0, "misses": 0, "falsePositives": 0}
              for state in ("working", "needsUser", "finished")}
    latencies = []
    details = []
    covered = set()
    valid_runs = 0
    unknown = samples = 0
    for run in runs:
        ground = sorted([r for r in truth if r["run"] == run], key=lambda r: r["time"])
        events = {r["event"] for r in ground}
        scenarios = {r["scenario"] for r in ground}
        terminal = [r for r in ground if r["event"] == "finished"]
        valid = (len(scenarios) == 1 and scenarios.issubset(set(SCENARIOS))
                 and {"idle", "submitted", "working", "finished", "end"}.issubset(events)
                 and all(r.get("outcome") in {"completed", "failed", "cancelled"} for r in terminal)
                 and ground[0]["event"] == "idle" and ground[-1]["event"] == "end")
        if not valid:
            details.append({"run": run, "error": "incomplete ground truth; excluded"})
            continue
        valid_runs += 1
        covered.update(scenarios)
        begin, end = ground[0]["time"], ground[-1]["time"]
        records = [r for r in detector if r.get("run") == run and begin <= r["time"] <= end]
        transitions = sorted([r for r in records if r["kind"] == "transition"], key=lambda r: r["time"])
        sampling = [r for r in records if r["kind"] == "sample"]
        samples += len(sampling)
        unknown += sum(r["state"] == "unknown" for r in sampling)
        # Only state ground truth bounds matching. submitted/userInput are timing annotations.
        state_truth = [r for r in ground if r["event"] in STATES]
        used = set()
        matches = []
        for i, expected in enumerate(state_truth):
            state = expected["event"]
            if state not in totals:
                continue
            upper = state_truth[i + 1]["time"] if i + 1 < len(state_truth) else end
            candidates = [(j, actual) for j, actual in enumerate(transitions)
                          if j not in used and actual["state"] == state
                          and expected["time"] <= actual["time"] < upper]
            if candidates:
                j, actual = candidates[0]
                used.add(j)
                latency = actual["time"] - expected["time"]
                totals[state]["truePositives"] += 1
                latencies.append(latency)
                matches.append({"state": state, "latencySeconds": latency})
            else:
                totals[state]["misses"] += 1
                matches.append({"state": state, "missed": True})
        for j, actual in enumerate(transitions):
            if j not in used and actual["state"] in totals:
                totals[actual["state"]]["falsePositives"] += 1
                matches.append({"state": actual["state"], "incorrectTime": actual["time"]})
        details.append({"run": run, "scenario": next(iter(scenarios)), "samples": len(sampling), "events": matches})
    for count in totals.values():
        tp, fn, fp = count["truePositives"], count["misses"], count["falsePositives"]
        count["precision"] = tp / (tp + fp) if tp + fp else None
        count["recall"] = tp / (tp + fn) if tp + fn else None
        # Strict event accuracy penalizes both missed and extra events.
        count["accuracy"] = tp / (tp + fn + fp) if tp + fn + fp else None
    quantitative = (valid_runs >= 30 and set(SCENARIOS).issubset(covered)
                    and all((totals[s]["accuracy"] or 0) >= .95 for s in ("working", "finished"))
                    and bool(latencies) and statistics.median(latencies) <= 3
                    and totals["finished"]["falsePositives"] == 0)
    return {
        "controlledRuns": valid_runs, "missingScenarios": sorted(set(SCENARIOS) - covered),
        "workingStarts": totals["working"], "needsUser": totals["needsUser"], "finishes": totals["finished"],
        "prematureOrExtraFinishes": totals["finished"]["falsePositives"],
        "medianLatencySeconds": statistics.median(latencies) if latencies else None,
        "worstLatencySeconds": max(latencies) if latencies else None,
        "unknownSamples": unknown, "totalSamples": samples,
        "unknownFrequency": unknown / samples if samples else None,
        "quantitativeGatePassed": quantitative,
        "recommendation": "DO_NOT_PROCEED",
        "reason": "Manual review of stable signals, needsUser false alarms, background/minimized behavior and limitations is still required. See docs/archive/phase0_report.md.",
        "runs": details,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    mark = sub.add_parser("mark")
    mark.add_argument("--truth", required=True)
    mark.add_argument("--run", required=True)
    mark.add_argument("--scenario", choices=SCENARIOS, required=True)
    mark.add_argument("--event", choices=sorted(STATES | {"submitted", "userInput", "end"}), required=True)
    mark.add_argument("--time", type=float, help="Observed Unix timestamp; default is now")
    mark.add_argument("--outcome", choices=["completed", "failed", "cancelled"])
    metric = sub.add_parser("analyze")
    metric.add_argument("--truth", required=True)
    metric.add_argument("--detector", required=True)
    metric.add_argument("--output", required=True)
    hash_command = sub.add_parser("hash")
    hash_command.add_argument("label", help="Exact control label/identifier; never enter prompts or source code")
    args = parser.parse_args()
    if args.command == "mark":
        if args.event == "finished" and not args.outcome:
            parser.error("finished requires --outcome")
        row = {"kind": "truth", "run": args.run, "scenario": args.scenario,
               "event": args.event, "time": args.time if args.time is not None else time.time()}
        if args.outcome:
            row["outcome"] = args.outcome
        with open(args.truth, "a") as stream:
            stream.write(json.dumps(row, sort_keys=True) + "\n")
        print(json.dumps(row))
    elif args.command == "hash":
        print(hashlib.sha256(args.label.encode()).hexdigest())
    else:
        result = analyze(read(args.truth), read(args.detector))
        Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps({k: v for k, v in result.items() if k != "runs"}, indent=2))


if __name__ == "__main__":
    main()
