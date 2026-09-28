import ApplicationServices
import Foundation

enum DiagnosticPolicy {
    static let domIdentifierAttribute = "AXDOMIdentifier"
    static let childrenInNavigationOrderAttribute = "AXChildrenInNavigationOrder"

    static let detectorLabelFingerprintRoles: Set<String> = [
        "AXWindow", "AXButton", "AXMenuButton", "AXProgressIndicator",
    ]

    /// Roles whose labels describe controls rather than user-authored document content.
    /// Container/content roles still expose structural metadata, but their labels are never read.
    static let labelFingerprintRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXComboBox", "AXDisclosureTriangle",
        "AXIncrementor", "AXMenu", "AXMenuButton", "AXMenuItem",
        "AXPopUpButton", "AXProgressIndicator", "AXRadioButton", "AXSlider",
        "AXStatusItem", "AXSwitch", "AXTabGroup", "AXToolbar", "AXWindow",
    ]

    static let labelAttributes = [
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXHelpAttribute as String,
    ]

    static let relationshipAttributes = [
        kAXChildrenAttribute as String,
        childrenInNavigationOrderAttribute,
        kAXVisibleChildrenAttribute as String,
        kAXContentsAttribute as String,
        kAXRowsAttribute as String,
        kAXColumnsAttribute as String,
        kAXTabsAttribute as String,
    ]

    /// Boolean state metadata exposed by native and Chromium AX providers. These
    /// values describe control state and cannot contain user-authored text.
    static let stateBooleanAttributes = [
        kAXElementBusyAttribute as String,
        kAXSelectedAttribute as String,
        "AXRequired",
        "AXVisited",
        kAXEditedAttribute as String,
        kAXMinimizedAttribute as String,
        kAXMainAttribute as String,
        kAXModalAttribute as String,
        "AXFullScreen",
    ]

    static func readableStringAttributes(for role: String) -> [String] {
        var names = [kAXIdentifierAttribute as String, domIdentifierAttribute]
        if labelFingerprintRoles.contains(role) { names.append(contentsOf: labelAttributes) }
        return names
    }

    static func readableBooleanAttributes(supported: Set<String>) -> [String] {
        stateBooleanAttributes.filter(supported.contains)
    }

    static func detectorStringAttributes(for role: String) -> [String] {
        var names = [kAXIdentifierAttribute as String]
        if detectorLabelFingerprintRoles.contains(role) {
            names.append(kAXTitleAttribute as String)
            names.append(kAXDescriptionAttribute as String)
        }
        return names
    }

    static func suppressedContentAttributes(for role: String, supported: Set<String>) -> [String] {
        guard !labelFingerprintRoles.contains(role) else { return [] }
        return labelAttributes.filter(supported.contains)
    }

    static func childRelationships(supported: Set<String>) -> [String] {
        let matches = relationshipAttributes.filter(supported.contains)
        // Some providers fail to enumerate attributes even though AXChildren works.
        return matches.isEmpty ? [kAXChildrenAttribute as String] : matches
    }

    static func sanitizedFingerprints(role: String, values: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: readableStringAttributes(for: role).compactMap { name in
            guard let value = values[name], !value.isEmpty else { return nil }
            return (name, fingerprint(value))
        })
    }
}
