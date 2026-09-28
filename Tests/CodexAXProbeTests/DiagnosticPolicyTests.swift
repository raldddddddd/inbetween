import ApplicationServices
import XCTest
@testable import CodexAXProbe

final class DiagnosticPolicyTests: XCTestCase {
    func testControlLabelsAreFingerprintedAndNeverReturnedRaw() {
        let raw = [
            kAXIdentifierAttribute as String: "stop-button",
            DiagnosticPolicy.domIdentifierAttribute: "stop-button-dom",
            kAXTitleAttribute as String: "Stop",
            kAXDescriptionAttribute as String: "Stop generation",
            kAXHelpAttribute as String: "Stops the current turn",
        ]

        let result = DiagnosticPolicy.sanitizedFingerprints(role: "AXButton", values: raw)

        XCTAssertEqual(Set(result.keys), Set(raw.keys))
        XCTAssertEqual(result[kAXTitleAttribute as String], fingerprint("Stop"))
        XCTAssertFalse(result.values.contains("Stop"))
        XCTAssertFalse(result.values.contains("Stop generation"))
    }

    func testContentAndContainerLabelsAreNotReadOrFingerprinted() {
        for role in ["AXStaticText", "AXTextArea", "AXWebArea", "AXGroup", "AXScrollArea"] {
            XCTAssertEqual(
                DiagnosticPolicy.readableStringAttributes(for: role),
                [kAXIdentifierAttribute as String, DiagnosticPolicy.domIdentifierAttribute]
            )
            let result = DiagnosticPolicy.sanitizedFingerprints(
                role: role,
                values: [
                    kAXIdentifierAttribute as String: "structural-id",
                    kAXTitleAttribute as String: "private prompt text",
                ]
            )
            XCTAssertEqual(result.count, 1)
            XCTAssertEqual(result[kAXIdentifierAttribute as String], fingerprint("structural-id"))
            XCTAssertNil(result[kAXTitleAttribute as String])
        }
    }

    func testSuppressedMetadataNamesAreReportedWithoutReadingValues() {
        let supported: Set<String> = [
            kAXTitleAttribute as String,
            kAXDescriptionAttribute as String,
            kAXValueAttribute as String,
        ]
        XCTAssertEqual(
            DiagnosticPolicy.suppressedContentAttributes(for: "AXStaticText", supported: supported),
            [kAXTitleAttribute as String, kAXDescriptionAttribute as String]
        )
        XCTAssertEqual(
            DiagnosticPolicy.suppressedContentAttributes(for: "AXButton", supported: supported),
            []
        )
    }

    func testAllSupportedStructuralChildRelationshipsAreTraversedInStableOrder() {
        let supported: Set<String> = [
            kAXTabsAttribute as String,
            kAXContentsAttribute as String,
            kAXVisibleChildrenAttribute as String,
            kAXChildrenAttribute as String,
            DiagnosticPolicy.childrenInNavigationOrderAttribute,
            "AXUnrelated",
        ]
        XCTAssertEqual(
            DiagnosticPolicy.childRelationships(supported: supported),
            [
                kAXChildrenAttribute as String,
                DiagnosticPolicy.childrenInNavigationOrderAttribute,
                kAXVisibleChildrenAttribute as String,
                kAXContentsAttribute as String,
                kAXTabsAttribute as String,
            ]
        )
    }

    func testOnlySupportedSafeBooleanStatesAreRead() {
        let supported: Set<String> = [
            kAXElementBusyAttribute as String,
            kAXSelectedAttribute as String,
            kAXValueAttribute as String,
            kAXTitleAttribute as String,
        ]

        XCTAssertEqual(
            DiagnosticPolicy.readableBooleanAttributes(supported: supported),
            [kAXElementBusyAttribute as String, kAXSelectedAttribute as String]
        )
    }

    func testChildrenFallbackWhenProviderCannotEnumerateAttributes() {
        XCTAssertEqual(
            DiagnosticPolicy.childRelationships(supported: []),
            [kAXChildrenAttribute as String]
        )
        XCTAssertEqual(
            DiagnosticPolicy.childRelationships(supported: [kAXRoleAttribute as String]),
            [kAXChildrenAttribute as String]
        )
    }

    func testDiagnosticExpansionDoesNotBroadenDetectorMetadata() {
        XCTAssertEqual(
            DiagnosticPolicy.detectorStringAttributes(for: "AXButton"),
            [
                kAXIdentifierAttribute as String,
                kAXTitleAttribute as String,
                kAXDescriptionAttribute as String,
            ]
        )
        XCTAssertEqual(
            DiagnosticPolicy.detectorStringAttributes(for: "AXToolbar"),
            [kAXIdentifierAttribute as String]
        )
        XCTAssertFalse(
            DiagnosticPolicy.detectorStringAttributes(for: "AXButton")
                .contains(kAXHelpAttribute as String)
        )
    }
}
