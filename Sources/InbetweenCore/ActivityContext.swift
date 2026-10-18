import Foundation

public enum UserPresenceState: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case idle
    case away
}

public enum ActivityResourceKind: String, Codable, Sendable {
    case workspace
    case project
    case document
    case folder
    case terminal
}

/// The local mechanism that supplied a context value. It stores source kinds,
/// never additional activity content.
public enum ActivityContextValueSource: String, Codable, Equatable, Sendable {
    case foregroundApplication
    case accessibility
    case browserAppleScript
    case applicationBundle
    case parserDerived
    case recentInputEstimate
    case syntheticDemo
    case legacyUnknown
}

public struct ActivityContextProvenance: Codable, Equatable, Sendable {
    public let applicationIdentity: ActivityContextValueSource
    public let applicationCategory: ActivityContextValueSource?
    public let windowTitle: ActivityContextValueSource?
    public let browserURL: ActivityContextValueSource?
    public let browserPageTitle: ActivityContextValueSource?
    public let browserDomain: ActivityContextValueSource?
    public let resourceMetadata: ActivityContextValueSource?
    public let presenceEstimate: ActivityContextValueSource?

    public init(
        applicationIdentity: ActivityContextValueSource = .legacyUnknown,
        applicationCategory: ActivityContextValueSource? = nil,
        windowTitle: ActivityContextValueSource? = nil,
        browserURL: ActivityContextValueSource? = nil,
        browserPageTitle: ActivityContextValueSource? = nil,
        browserDomain: ActivityContextValueSource? = nil,
        resourceMetadata: ActivityContextValueSource? = nil,
        presenceEstimate: ActivityContextValueSource? = nil
    ) {
        self.applicationIdentity = applicationIdentity
        self.applicationCategory = applicationCategory
        self.windowTitle = windowTitle
        self.browserURL = browserURL
        self.browserPageTitle = browserPageTitle
        self.browserDomain = browserDomain
        self.resourceMetadata = resourceMetadata
        self.presenceEstimate = presenceEstimate
    }

    public static let syntheticDemo = ActivityContextProvenance(
        applicationIdentity: .syntheticDemo,
        applicationCategory: .syntheticDemo,
        windowTitle: .syntheticDemo,
        browserURL: .syntheticDemo,
        browserPageTitle: .syntheticDemo,
        browserDomain: .syntheticDemo,
        resourceMetadata: .syntheticDemo,
        presenceEstimate: .syntheticDemo
    )

    public var presentationDescription: String {
        if applicationIdentity == .syntheticDemo { return "Synthetic demo context." }
        var details: [String] = []
        if applicationIdentity == .foregroundApplication {
            details.append("Application identity sampled from the macOS foreground app")
        }
        if applicationCategory == .applicationBundle {
            details.append("App category read from bundle metadata")
        }
        if windowTitle == .accessibility {
            details.append("Window title read through Accessibility")
        }
        let browserSource = browserURL ?? browserPageTitle
        switch browserSource {
        case .accessibility: details.append("Browser URL or title read through Accessibility")
        case .browserAppleScript: details.append("Browser URL or title read through browser metadata")
        default: break
        }
        if browserDomain == .parserDerived {
            details.append("Browser domain derived from the available URL")
        }
        if resourceMetadata == .parserDerived {
            details.append("Project, workspace, document, or terminal details derived from available metadata")
        }
        if presenceEstimate == .recentInputEstimate {
            details.append("Presence estimated from recent input; it does not measure attention")
        }
        return details.isEmpty ? "Source details were not recorded for this context." : details.joined(separator: ". ") + "."
    }
}

public struct ActivityContextEnrichment: Equatable, Sendable {
    public let browserURL: String?
    public let browserDomain: String?
    public let browserPageTitle: String?
    public let resourceKind: ActivityResourceKind?
    public let resourceName: String?
    public let documentName: String?
    public let resourcePath: String?
    public let source: ActivityContextValueSource

    public init(
        browserURL: String? = nil,
        browserDomain: String? = nil,
        browserPageTitle: String? = nil,
        resourceKind: ActivityResourceKind? = nil,
        resourceName: String? = nil,
        documentName: String? = nil,
        resourcePath: String? = nil,
        source: ActivityContextValueSource = .parserDerived
    ) {
        self.browserURL = browserURL
        self.browserDomain = browserDomain
        self.browserPageTitle = browserPageTitle
        self.resourceKind = resourceKind
        self.resourceName = resourceName
        self.documentName = documentName
        self.resourcePath = resourcePath
        self.source = source
    }
}

public struct ActivityContext: Codable, Equatable, Sendable {
    public static let maximumApplicationNameLength = 200
    public static let maximumTitleLength = 500
    public static let maximumURLLength = 4_096
    public static let maximumPathLength = 4_096

    private static let safeBrowserURLSchemes: Set<String> = [
        "about",
        "brave",
        "chrome",
        "chrome-extension",
        "edge",
        "file",
        "ftp",
        "http",
        "https",
        "safari-extension",
        "safari-web-extension"
    ]

    public let applicationBundleIdentifier: String
    public let applicationName: String
    public let applicationCategoryIdentifier: String?
    public let windowTitle: String?
    public let browserDomain: String?
    public let browserPageTitle: String?
    public let browserURL: String?
    public let resourceKind: ActivityResourceKind?
    public let resourceName: String?
    public let documentName: String?
    public let resourcePath: String?
    public let presenceState: UserPresenceState?
    public let provenance: ActivityContextProvenance

    public init?(
        applicationBundleIdentifier: String,
        applicationName: String,
        applicationCategoryIdentifier: String? = nil,
        windowTitle: String? = nil,
        browserDomain: String? = nil,
        browserPageTitle: String? = nil,
        browserURL: String? = nil,
        resourceKind: ActivityResourceKind? = nil,
        resourceName: String? = nil,
        documentName: String? = nil,
        resourcePath: String? = nil,
        presenceState: UserPresenceState? = nil,
        provenance: ActivityContextProvenance = ActivityContextProvenance()
    ) {
        guard let bundleIdentifier = Self.normalized(
            applicationBundleIdentifier,
            maximumLength: 255
        ), bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
        let name = Self.normalized(
            applicationName,
            maximumLength: Self.maximumApplicationNameLength
        ) else {
            return nil
        }

        let normalizedURL = Self.sanitizedBrowserURL(browserURL)

        let derivedDomain = normalizedURL.flatMap(Self.normalizedBrowserDomain(from:))
        let normalizedDomain = Self.normalized(
            browserDomain ?? derivedDomain,
            maximumLength: 253
        )
        if let normalizedDomain,
           normalizedDomain.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || normalizedDomain.rangeOfCharacter(from: CharacterSet(charactersIn: "/?#")) != nil {
            return nil
        }

        self.applicationBundleIdentifier = bundleIdentifier
        self.applicationName = name
        self.applicationCategoryIdentifier = Self.normalized(
            applicationCategoryIdentifier,
            maximumLength: 255
        )
        self.windowTitle = Self.normalized(windowTitle, maximumLength: Self.maximumTitleLength)
        self.browserDomain = normalizedDomain?.lowercased()
        self.browserPageTitle = Self.normalized(
            browserPageTitle,
            maximumLength: Self.maximumTitleLength
        )
        self.browserURL = normalizedURL
        self.resourceKind = resourceKind
        self.resourceName = Self.normalized(
            resourceName,
            maximumLength: Self.maximumTitleLength
        )
        self.documentName = Self.normalized(
            documentName,
            maximumLength: Self.maximumTitleLength
        )
        self.resourcePath = Self.normalized(
            resourcePath,
            maximumLength: Self.maximumPathLength
        )
        self.presenceState = presenceState
        self.provenance = provenance
    }

    public func enriching(
        with enrichment: ActivityContextEnrichment?,
        presenceState: UserPresenceState?
    ) -> ActivityContext? {
        let resourceWasDerived = enrichment.map {
            $0.resourceKind != nil || $0.resourceName != nil || $0.documentName != nil || $0.resourcePath != nil
        } ?? false
        let browserSource = enrichment?.source
        return ActivityContext(
            applicationBundleIdentifier: applicationBundleIdentifier,
            applicationName: applicationName,
            applicationCategoryIdentifier: applicationCategoryIdentifier,
            windowTitle: windowTitle,
            browserDomain: enrichment?.browserDomain ?? browserDomain,
            browserPageTitle: enrichment?.browserPageTitle ?? browserPageTitle,
            browserURL: enrichment?.browserURL ?? browserURL,
            resourceKind: enrichment?.resourceKind ?? resourceKind,
            resourceName: enrichment?.resourceName ?? resourceName,
            documentName: enrichment?.documentName ?? documentName,
            resourcePath: enrichment?.resourcePath ?? resourcePath,
            presenceState: presenceState,
            provenance: ActivityContextProvenance(
                applicationIdentity: provenance.applicationIdentity,
                applicationCategory: provenance.applicationCategory,
                windowTitle: provenance.windowTitle,
                browserURL: enrichment?.browserURL != nil ? browserSource : provenance.browserURL,
                browserPageTitle: enrichment?.browserPageTitle != nil ? browserSource : provenance.browserPageTitle,
                browserDomain: enrichment?.browserDomain != nil ? .parserDerived : provenance.browserDomain,
                resourceMetadata: resourceWasDerived ? .parserDerived : provenance.resourceMetadata,
                presenceEstimate: presenceState == nil ? nil : .recentInputEstimate
            )
        )
    }

    public var compactDisplayComponents: [String] {
        var components = [applicationName]
        if let browserDomain {
            Self.appendDistinct(browserDomain, to: &components)
            if let browserPageTitle {
                Self.appendDistinct(browserPageTitle, to: &components)
            }
            return components
        }

        if (resourceKind == .terminal || resourceKind == .folder), let resourcePath {
            Self.appendDistinct(Self.abbreviatedPath(resourcePath), to: &components)
            if let documentName {
                Self.appendDistinct(documentName, to: &components)
            }
            return components
        }

        if let resourceName {
            Self.appendDistinct(resourceName, to: &components)
        }
        if let documentName {
            Self.appendDistinct(documentName, to: &components)
        }
        if resourceName == nil, documentName == nil, let resourcePath {
            Self.appendDistinct(resourcePath, to: &components)
        }
        if components.count == 1, let windowTitle {
            Self.appendDistinct(windowTitle, to: &components)
        }
        return components
    }

    public var hasRichMetadata: Bool {
        windowTitle != nil
            || browserDomain != nil
            || browserPageTitle != nil
            || browserURL != nil
            || resourceName != nil
            || documentName != nil
            || resourcePath != nil
    }

    public func representsSameActivity(as other: ActivityContext) -> Bool {
        applicationBundleIdentifier == other.applicationBundleIdentifier
            && applicationName == other.applicationName
            && applicationCategoryIdentifier == other.applicationCategoryIdentifier
            && windowTitle == other.windowTitle
            && browserDomain == other.browserDomain
            && browserPageTitle == other.browserPageTitle
            && browserURL == other.browserURL
            && resourceKind == other.resourceKind
            && resourceName == other.resourceName
            && documentName == other.documentName
            && resourcePath == other.resourcePath
            && provenance == other.provenance
    }

    private enum CodingKeys: String, CodingKey {
        case applicationBundleIdentifier
        case applicationName
        case applicationCategoryIdentifier
        case windowTitle
        case browserDomain
        case browserPageTitle
        case browserURL
        case resourceKind
        case resourceName
        case documentName
        case resourcePath
        case presenceState
        case provenance
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let context = Self(
            applicationBundleIdentifier: try container.decode(
                String.self,
                forKey: .applicationBundleIdentifier
            ),
            applicationName: try container.decode(String.self, forKey: .applicationName),
            applicationCategoryIdentifier: try container.decodeIfPresent(
                String.self,
                forKey: .applicationCategoryIdentifier
            ),
            windowTitle: try container.decodeIfPresent(String.self, forKey: .windowTitle),
            browserDomain: try container.decodeIfPresent(String.self, forKey: .browserDomain),
            browserPageTitle: try container.decodeIfPresent(
                String.self,
                forKey: .browserPageTitle
            ),
            browserURL: try container.decodeIfPresent(String.self, forKey: .browserURL),
            resourceKind: try container.decodeIfPresent(
                ActivityResourceKind.self,
                forKey: .resourceKind
            ),
            resourceName: try container.decodeIfPresent(String.self, forKey: .resourceName),
            documentName: try container.decodeIfPresent(String.self, forKey: .documentName),
            resourcePath: try container.decodeIfPresent(String.self, forKey: .resourcePath),
            presenceState: try container.decodeIfPresent(
                UserPresenceState.self,
                forKey: .presenceState
            ),
            provenance: try container.decodeIfPresent(
                ActivityContextProvenance.self,
                forKey: .provenance
            ) ?? ActivityContextProvenance()
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid persisted activity context"
                )
            )
        }
        self = context
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applicationBundleIdentifier, forKey: .applicationBundleIdentifier)
        try container.encode(applicationName, forKey: .applicationName)
        try container.encodeIfPresent(
            applicationCategoryIdentifier,
            forKey: .applicationCategoryIdentifier
        )
        try container.encodeIfPresent(windowTitle, forKey: .windowTitle)
        try container.encodeIfPresent(browserDomain, forKey: .browserDomain)
        try container.encodeIfPresent(browserPageTitle, forKey: .browserPageTitle)
        try container.encodeIfPresent(browserURL, forKey: .browserURL)
        try container.encodeIfPresent(resourceKind, forKey: .resourceKind)
        try container.encodeIfPresent(resourceName, forKey: .resourceName)
        try container.encodeIfPresent(documentName, forKey: .documentName)
        try container.encodeIfPresent(resourcePath, forKey: .resourcePath)
        try container.encodeIfPresent(presenceState, forKey: .presenceState)
        try container.encode(provenance, forKey: .provenance)
    }

    private static func normalized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count <= maximumLength else { return nil }
        return cleaned
    }

    private static func normalizedBrowserDomain(from urlString: String) -> String? {
        URLComponents(string: urlString)?.host?.lowercased()
    }

    /// Keeps useful navigation metadata without persisting schemes whose URL
    /// payload can itself contain executable script or complete page content.
    static func sanitizedBrowserURL(_ value: String?) -> String? {
        guard let value = normalized(value, maximumLength: maximumURLLength),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              safeBrowserURLSchemes.contains(scheme)
        else {
            return nil
        }

        switch scheme {
        case "http", "https", "ftp":
            guard components.host?.isEmpty == false else { return nil }
        case "file":
            guard URL(string: value)?.isFileURL == true else { return nil }
        default:
            break
        }
        return value
    }

    private static func appendDistinct(_ value: String, to values: inout [String]) {
        guard !values.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else {
            return
        }
        values.append(value)
    }

    private static func abbreviatedPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

public struct ActivityObservation: Equatable, Sendable {
    public let context: ActivityContext
    public let observedAt: Date

    public init(context: ActivityContext, observedAt: Date) {
        self.context = context
        self.observedAt = observedAt
    }
}

public struct ActivitySegment: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let waitSessionID: UUID
    public let context: ActivityContext
    public let startedAt: Date
    public var endedAt: Date?
    public var duration: TimeInterval?
    public var lastObservedAt: Date

    public init(
        id: UUID = UUID(),
        waitSessionID: UUID,
        context: ActivityContext,
        startedAt: Date,
        endedAt: Date? = nil,
        duration: TimeInterval? = nil,
        lastObservedAt: Date? = nil
    ) {
        self.id = id
        self.waitSessionID = waitSessionID
        self.context = context
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.lastObservedAt = lastObservedAt ?? endedAt ?? startedAt
    }

    public func elapsed(at date: Date) -> TimeInterval {
        duration ?? max(0, date.timeIntervalSince(startedAt))
    }

    private enum CodingKeys: String, CodingKey {
        case id, waitSessionID, context, startedAt, endedAt, duration, lastObservedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        waitSessionID = try container.decode(UUID.self, forKey: .waitSessionID)
        context = try container.decode(ActivityContext.self, forKey: .context)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        lastObservedAt = try container.decodeIfPresent(Date.self, forKey: .lastObservedAt)
            ?? endedAt
            ?? startedAt
    }
}

public enum ActivityUpdate: Equatable, Sendable {
    case started(UUID)
    case transitioned(UUID)
    case coalesced(UUID)
    case ignored
}

public enum ActivityCollectionTransition: Equatable, Sendable {
    case suspended(UUID)
    case resumed(UUID)
    case ignored
}
