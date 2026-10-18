from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
APP_SOURCE = ROOT / "Sources" / "InbetweenApp" / "InbetweenApp.swift"
CREDENTIAL_SOURCE = ROOT / "Sources" / "InbetweenApp" / "AICredentialStore.swift"
READ_HELPER_SOURCE = ROOT / "Sources" / "InbetweenCore" / "AICredentialRead.swift"


def debug_only_line_numbers(source: str) -> set[int]:
    stack: list[bool] = []
    lines: set[int] = set()
    for number, line in enumerate(source.splitlines(), start=1):
        directive = line.strip()
        if directive.startswith("#if "):
            parent_active = stack[-1] if stack else directive == "#if DEBUG"
            stack.append(parent_active and directive == "#if DEBUG")
        elif directive == "#endif" and stack:
            stack.pop()
        if stack and stack[-1]:
            lines.add(number)
    return lines


class ReleaseUIContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = APP_SOURCE.read_text()

    def test_dashboard_has_no_needs_review_destination_or_queue_copy(self) -> None:
        destination = self.source.split("enum DashboardDestination", 1)[1].split("@main", 1)[0]
        self.assertNotIn("case review", destination)
        self.assertNotIn("Needs Review", self.source)
        self.assertNotIn("Nothing needs review", self.source)
        self.assertNotIn("pendingReviewItems", self.source)

    def test_history_keeps_productive_and_distracted_correction_controls(self) -> None:
        self.assertIn('classificationButton("Productive", value: .productive)', self.source)
        self.assertIn('classificationButton("Distracted", value: .distracted)', self.source)
        self.assertIn("setSliceClassificationOverride(classification, for: unit)", self.source)
        self.assertIn("setManualClassificationOverride(value, for: session.id)", self.source)

    def test_reflection_keeps_local_metrics_and_evidence_navigation(self) -> None:
        self.assertIn("private var localSummary: some View", self.source)
        self.assertIn('metric("Productive", metrics.productiveSeconds)', self.source)
        self.assertIn('metric("Distracted", metrics.distractedSeconds)', self.source)
        self.assertIn("onViewEvidence(evidenceID, scope)", self.source)
        self.assertNotIn("Answer grounded in linked local evidence.", self.source)

    def test_snapshot_disclosure_is_debug_only(self) -> None:
        debug_lines = debug_only_line_numbers(self.source)
        for number, line in enumerate(self.source.splitlines(), start=1):
            if "Developer · snapshot sent" in line or "SanitizedInsightSnapshotDisclosure(" in line:
                self.assertIn(number, debug_lines)

    def test_isolated_ui_mode_does_not_read_the_real_keychain_on_launch(self) -> None:
        self.assertIn("InMemoryAICredentialStore()", self.source)
        refresh = self.source.split("private func refreshAIConfiguration()", 1)[1]
        refresh = refresh.split("private func applyAIConfiguration(", 1)[0]
        self.assertIn("Task.detached", refresh)
        self.assertIn("apiKeyWithTimeout(from: credentialStore)", refresh)
        self.assertNotIn("aiCredentialStore.apiKey()", refresh)

    def test_isolated_keychain_verification_uses_the_real_store_without_prompts(self) -> None:
        self.assertIn("isolatedDataDirectory != nil", self.source)
        self.assertIn("Self.testKeychainArgument", self.source)
        self.assertIn("KeychainAICredentialStore()", self.source)
        credential_source = CREDENTIAL_SOURCE.read_text()
        self.assertIn("kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail", credential_source)
        read_helper = READ_HELPER_SOURCE.read_text()
        self.assertIn("AICredentialReadTimeoutError", read_helper)
        self.assertIn("DispatchQueue.main.asyncAfter(deadline: .now() + timeout)", read_helper)

    def test_reflection_verification_window_requires_explicit_test_argument(self) -> None:
        self.assertIn('arguments.contains("--inbetween-test-open-reflection")', self.source)
        self.assertIn('window.title = "Reflection Verification"', self.source)
        self.assertIn("NSHostingView(rootView: DashboardView(model: model))", self.source)

    def test_isolated_ui_mode_has_a_distinct_menu_bar_identity(self) -> None:
        self.assertIn('isIsolatedUITest ? "Inbetween UI Test" : "Inbetween"', self.source)
        self.assertIn('isIsolatedUITest ? "testtube.2" : model.menuBarSymbol', self.source)
        self.assertIn('"INBETWEEN_TEST_DATA_DIRECTORY"', self.source)

    def test_isolated_ui_mode_has_deterministic_destination_commands(self) -> None:
        self.assertIn('Button("Open History") { open(.history) }', self.source)
        self.assertIn('Button("Open Reflection") { open(.reflection) }', self.source)

    def test_reflection_setup_state_hides_credential_and_provider_details(self) -> None:
        status = self.source.split("func reflectionStatus(for scope:", 1)[1].split("func activateReflectionScope", 1)[0]
        self.assertIn("Set up Reflection in Settings to ask questions.", status)
        self.assertNotIn("aiConfigurationStatus", status)

    def test_reflection_suggestion_action_submits_the_selected_question_directly(self) -> None:
        reflection = self.source.split("private struct ReflectionChatSection", 1)[1]
        self.assertIn("submit(suggestion: suggestion)", reflection)
        self.assertIn("ReflectionQuestionSubmission.resolve(draft: question, suggestion: suggestion)", reflection)
        self.assertNotIn("question = suggestion", reflection)

    def test_reflection_suggestions_are_snapshot_aware_and_empty_periods_are_explained(self) -> None:
        reflection = self.source.split("private struct ReflectionChatSection", 1)[1]
        self.assertIn("ReflectionSuggestedQuestions.forSnapshot(prepared.payload)", reflection)
        self.assertIn("There isn’t enough recorded activity in this period to suggest a question.", reflection)


if __name__ == "__main__":
    unittest.main()
