import Foundation

public struct UserPresencePolicy: Equatable, Sendable {
    public static let defaultIdleThreshold: TimeInterval = 30
    public static let defaultAwayThreshold: TimeInterval = 120

    public let idleThreshold: TimeInterval
    public let awayThreshold: TimeInterval

    public init(
        idleThreshold: TimeInterval = Self.defaultIdleThreshold,
        awayThreshold: TimeInterval = Self.defaultAwayThreshold
    ) {
        precondition(idleThreshold >= 0)
        precondition(awayThreshold > idleThreshold)
        self.idleThreshold = idleThreshold
        self.awayThreshold = awayThreshold
    }

    public func state(secondsSinceLastInput seconds: TimeInterval?) -> UserPresenceState? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        if seconds >= awayThreshold { return .away }
        if seconds >= idleThreshold { return .idle }
        return .active
    }
}

public enum ActivityEnrichmentParser {
    public static func browser(
        urlString: String?,
        pageTitle: String?,
        source: ActivityContextValueSource = .parserDerived
    ) -> ActivityContextEnrichment? {
        let urlString = ActivityContext.sanitizedBrowserURL(urlString)
        let pageTitle = normalized(pageTitle, maximumLength: ActivityContext.maximumTitleLength)
        guard urlString != nil || pageTitle != nil else { return nil }

        let domain = urlString.flatMap { URLComponents(string: $0)?.host?.lowercased() }
        return ActivityContextEnrichment(
            browserURL: urlString,
            browserDomain: domain,
            browserPageTitle: pageTitle,
            source: source
        )
    }

    public static func nativeApplication(
        bundleIdentifier: String,
        windowTitle: String?,
        documentURLString: String?
    ) -> ActivityContextEnrichment? {
        switch bundleIdentifier {
        case "com.apple.dt.Xcode":
            return xcode(windowTitle: windowTitle, documentURLString: documentURLString)
        case "com.microsoft.VSCode":
            return visualStudioCode(
                windowTitle: windowTitle,
                documentURLString: documentURLString
            )
        case "com.apple.finder":
            return finder(documentURLString: documentURLString)
        case "com.apple.Terminal", "com.googlecode.iterm2":
            return terminal(windowTitle: windowTitle, documentURLString: documentURLString)
        default:
            return nil
        }
    }

    private static func xcode(
        windowTitle: String?,
        documentURLString: String?
    ) -> ActivityContextEnrichment? {
        let fileURL = localFileURL(documentURLString)
        let path = fileURL?.path
        let extensionName = fileURL?.pathExtension.lowercased()
        let kind: ActivityResourceKind?
        switch extensionName {
        case "xcworkspace": kind = .workspace
        case "xcodeproj": kind = .project
        case .some: kind = .document
        case nil: kind = nil
        }

        let titleParts = editorTitleParts(windowTitle, applicationSuffix: "Xcode")
        let pathName = fileURL.map { $0.deletingPathExtension().lastPathComponent }
        let resourceName: String?
        let documentName: String?
        if kind == .workspace || kind == .project {
            resourceName = pathName ?? titleParts.last
            documentName = titleParts.count > 1 ? titleParts.first : nil
        } else {
            resourceName = titleParts.count > 1 ? titleParts.last : nil
            documentName = fileURL?.lastPathComponent ?? titleParts.first
        }

        guard kind != nil || resourceName != nil || documentName != nil || path != nil else {
            return nil
        }
        return ActivityContextEnrichment(
            resourceKind: kind ?? .document,
            resourceName: resourceName,
            documentName: documentName,
            resourcePath: path
        )
    }

    private static func visualStudioCode(
        windowTitle: String?,
        documentURLString: String?
    ) -> ActivityContextEnrichment? {
        let fileURL = localFileURL(documentURLString)
        let parts = editorTitleParts(windowTitle, applicationSuffix: "Visual Studio Code")
        let documentName = fileURL?.lastPathComponent ?? parts.first
        let workspaceName = parts.count > 1 ? parts.last : nil
        guard documentName != nil || workspaceName != nil || fileURL != nil else { return nil }
        return ActivityContextEnrichment(
            resourceKind: workspaceName == nil ? .document : .workspace,
            resourceName: workspaceName,
            documentName: documentName,
            resourcePath: fileURL?.path
        )
    }

    private static func finder(documentURLString: String?) -> ActivityContextEnrichment? {
        guard let fileURL = localFileURL(documentURLString) else { return nil }
        return ActivityContextEnrichment(
            resourceKind: .folder,
            resourceName: fileURL.lastPathComponent,
            resourcePath: fileURL.path
        )
    }

    private static func terminal(
        windowTitle: String?,
        documentURLString: String?
    ) -> ActivityContextEnrichment? {
        if let fileURL = localFileURL(documentURLString) {
            return ActivityContextEnrichment(
                resourceKind: .terminal,
                resourceName: fileURL.lastPathComponent,
                resourcePath: fileURL.path
            )
        }

        // Terminal does not expose a working directory through a stable public
        // scripting property. Preserve its useful title as the base context and
        // avoid guessing a path from shell-specific title formatting.
        guard normalized(windowTitle, maximumLength: ActivityContext.maximumTitleLength) != nil else {
            return nil
        }
        return ActivityContextEnrichment(resourceKind: .terminal)
    }

    private static func editorTitleParts(
        _ title: String?,
        applicationSuffix: String
    ) -> [String] {
        guard let title = normalized(title, maximumLength: ActivityContext.maximumTitleLength) else {
            return []
        }
        var parts = title
            .components(separatedBy: " — ")
            .compactMap { normalized($0, maximumLength: ActivityContext.maximumTitleLength) }
        if parts.last?.caseInsensitiveCompare(applicationSuffix) == .orderedSame {
            parts.removeLast()
        }
        return parts
    }

    private static func localFileURL(_ value: String?) -> URL? {
        guard let value = normalized(value, maximumLength: ActivityContext.maximumPathLength) else {
            return nil
        }
        if let url = URL(string: value), url.isFileURL {
            return url
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value)
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
}

public struct ActivityHistoryGroup: Equatable, Sendable {
    public let context: ActivityContext
    public let sourceSegmentIDs: [UUID]
    public let startedAt: Date
    public let endedAt: Date?
    public let knownDuration: TimeInterval
    public let hasIncompleteDuration: Bool
    public let presenceDurations: [UserPresenceState: TimeInterval]

    public var segmentCount: Int { sourceSegmentIDs.count }
    public var displayComponents: [String] { context.compactDisplayComponents }
}

public enum ActivityHistoryGrouper {
    public static func grouped(_ segments: [ActivitySegment]) -> [ActivityHistoryGroup] {
        var groups: [MutableGroup] = []
        for segment in segments {
            if let lastIndex = groups.indices.last,
               groups[lastIndex].context.representsSameActivity(as: segment.context) {
                groups[lastIndex].append(segment)
            } else {
                groups.append(MutableGroup(segment))
            }
        }
        return groups.map(\.value)
    }

    private struct MutableGroup {
        let context: ActivityContext
        var sourceSegmentIDs: [UUID]
        let startedAt: Date
        var endedAt: Date?
        var knownDuration: TimeInterval
        var hasIncompleteDuration: Bool
        var presenceDurations: [UserPresenceState: TimeInterval]

        init(_ segment: ActivitySegment) {
            context = segment.context
            sourceSegmentIDs = [segment.id]
            startedAt = segment.startedAt
            endedAt = segment.endedAt
            knownDuration = max(0, segment.duration ?? 0)
            hasIncompleteDuration = segment.duration == nil
            if let presence = segment.context.presenceState, let duration = segment.duration {
                presenceDurations = [presence: max(0, duration)]
            } else {
                presenceDurations = [:]
            }
        }

        mutating func append(_ segment: ActivitySegment) {
            sourceSegmentIDs.append(segment.id)
            endedAt = segment.endedAt
            knownDuration += max(0, segment.duration ?? 0)
            hasIncompleteDuration = hasIncompleteDuration || segment.duration == nil
            if let presence = segment.context.presenceState, let duration = segment.duration {
                presenceDurations[presence, default: 0] += max(0, duration)
            }
        }

        var value: ActivityHistoryGroup {
            ActivityHistoryGroup(
                context: context,
                sourceSegmentIDs: sourceSegmentIDs,
                startedAt: startedAt,
                endedAt: endedAt,
                knownDuration: knownDuration,
                hasIncompleteDuration: hasIncompleteDuration,
                presenceDurations: presenceDurations
            )
        }
    }
}
