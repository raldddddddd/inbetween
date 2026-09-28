import json
import tempfile
import unittest
from pathlib import Path

import semantic_compare


class SemanticCompareInputTests(unittest.TestCase):
    def test_scoped_corrected_history_export_is_accepted(self):
        document = {
            "schemaVersion": 2,
            "examples": [{
                "id": "corrected-context-1",
                "semanticInput": "Page: Swift documentation | Domain: developer.apple.com",
                "correctionScope": "slice",
                "manualClassification": "Productive",
                "automaticClassification": "Unclassified",
                "automaticReasonCodes": ["noStrongEvidence"],
                "automaticAgreesWithManualCorrection": False,
                "semanticCategoryLabel": None,
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "export.json"
            path.write_text(json.dumps(document))

            examples = semantic_compare.load_examples([path])

        self.assertEqual(len(examples), 1)
        self.assertEqual(examples[0]["correction_scope"], "slice")
        self.assertEqual(examples[0]["manual_label"], "Productive")

    def test_schema_one_exports_are_treated_as_legacy_whole_wait(self):
        document = {
            "schemaVersion": 1,
            "examples": [{
                "id": "legacy-context",
                "semanticInput": "App: Xcode | Window: Project",
                "manualClassification": "Productive",
                "automaticClassification": "Productive",
                "automaticReasonCodes": [],
                "automaticAgreesWithManualCorrection": True,
                "semanticCategoryLabel": None,
            }],
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "export.json"
            path.write_text(json.dumps(document))

            examples = semantic_compare.load_examples([path])

        self.assertEqual(examples[0]["correction_scope"], "legacyWholeWait")


if __name__ == "__main__":
    unittest.main()
