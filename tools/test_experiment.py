import unittest
from experiment import analyze


class MetricsTests(unittest.TestCase):
    def ground(self):
        return [{"run": "r1", "scenario": "text", "event": event, "time": at,
                 **({"outcome": "completed"} if event == "finished" else {})}
                for event, at in [("idle", 0), ("submitted", 1), ("working", 2),
                                  ("needsUser", 5), ("userInput", 7), ("working", 8),
                                  ("finished", 12), ("end", 16)]]

    def test_matches_latency_and_unknown(self):
        log = [{"kind": "transition", "run": "r1", "state": state, "time": at}
               for state, at in [("working", 3), ("needsUser", 6), ("working", 9), ("finished", 14)]]
        log.append({"kind": "sample", "run": "r1", "state": "unknown", "time": 4})
        result = analyze(self.ground(), log)
        self.assertEqual(result["workingStarts"]["truePositives"], 2)
        self.assertEqual(result["finishes"]["accuracy"], 1)
        self.assertEqual(result["medianLatencySeconds"], 1)
        self.assertEqual(result["worstLatencySeconds"], 2)
        self.assertEqual(result["unknownFrequency"], 1)
        self.assertFalse(result["quantitativeGatePassed"])

    def test_premature_finish_and_misses(self):
        log = [{"kind": "transition", "run": "r1", "state": "finished", "time": 4}]
        result = analyze(self.ground(), log)
        self.assertEqual(result["prematureOrExtraFinishes"], 1)
        self.assertEqual(result["finishes"]["misses"], 1)
        self.assertEqual(result["workingStarts"]["misses"], 2)
        self.assertEqual(result["needsUser"]["misses"], 1)

    def test_incomplete_runs_excluded(self):
        result = analyze(self.ground()[:-1], [])
        self.assertEqual(result["controlledRuns"], 0)


if __name__ == "__main__":
    unittest.main()
