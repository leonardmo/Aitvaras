import Foundation

/// The external identity attached to connector events. This is deliberately
/// separate from the event's text: approving a source only permits routing and
/// triage; it never turns that source's content into instructions.
public struct ExternalMessageSource: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case email
        case notification
        case configuredService
    }

    public static let maximumIdentityCharacters = 320
    public static let maximumDisplayNameCharacters = 320
    public static let maximumApplicationIDCharacters = 320

    public var kind: Kind
    /// Canonical address/label used for exact matching. Unparseable email
    /// headers use a stable opaque key and can never be approved.
    public var identity: String
    public var displayName: String
    public var domain: String?
    public var applicationID: String
    public var canApproveExactSender: Bool

    public var requiresSenderApproval: Bool { kind != .configuredService }

    public init(
        kind: Kind,
        identity: String,
        displayName: String,
        domain: String? = nil,
        applicationID: String = "",
        canApproveExactSender: Bool
    ) {
        self.kind = kind
        self.identity = String(identity.prefix(Self.maximumIdentityCharacters))
        self.displayName = String(displayName.prefix(Self.maximumDisplayNameCharacters))
        self.domain = domain
        self.applicationID = String(applicationID.prefix(Self.maximumApplicationIDCharacters))
        self.canApproveExactSender = canApproveExactSender
    }

    public static func email(senderHeader: String) -> ExternalMessageSource {
        if let sender = EmailSenderIdentity.parse(senderHeader) {
            return ExternalMessageSource(
                kind: .email,
                identity: sender.address,
                displayName: sender.displayName,
                domain: sender.domain,
                canApproveExactSender: true)
        }
        let display = MessageTrustPolicy.singleLine(senderHeader)
        return ExternalMessageSource(
            kind: .email,
            identity: "unparseable:" + StableIdentifier.short([senderHeader]),
            displayName: display.isEmpty ? "Unknown mail sender" : display,
            canApproveExactSender: false)
    }

    public static func notification(
        applicationID: String,
        applicationName: String,
        senderLabel: String
    ) -> ExternalMessageSource {
        let normalized = MessageTrustPolicy.normalizedNotificationLabel(senderLabel)
        let visibleLabel = MessageTrustPolicy.singleLine(senderLabel)
        let app = MessageTrustPolicy.singleLine(applicationName)
        let display = visibleLabel.isEmpty ? app : "\(app) · \(visibleLabel)"
        return ExternalMessageSource(
            kind: .notification,
            identity: normalized.isEmpty ? "unknown" : normalized,
            displayName: display.isEmpty ? "Unknown notification sender" : display,
            applicationID: applicationID,
            canApproveExactSender: !normalized.isEmpty && !applicationID.isEmpty)
    }

    public static func configuredService(
        id: String,
        displayName: String
    ) -> ExternalMessageSource {
        ExternalMessageSource(
            kind: .configuredService,
            identity: MessageTrustPolicy.normalizedNotificationLabel(id),
            displayName: MessageTrustPolicy.singleLine(displayName),
            canApproveExactSender: false)
    }
}

public struct EmailSenderIdentity: Sendable, Equatable {
    public var address: String
    public var domain: String
    public var displayName: String

    public init(address: String, domain: String, displayName: String) {
        self.address = address
        self.domain = domain
        self.displayName = displayName
    }

    /// Extract the first syntactically ordinary ASCII mailbox from an Apple
    /// Mail sender header. Internationalized/ambiguous forms stay unapproved
    /// rather than being normalized into a potentially different identity.
    public static func parse(_ header: String) -> EmailSenderIdentity? {
        let bounded = String(header.prefix(2_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        let rawDisplay: String
        if let opening = bounded.firstIndex(of: "<"),
           let closing = bounded[bounded.index(after: opening)...].firstIndex(of: ">") {
            candidate = String(bounded[bounded.index(after: opening)..<closing])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rawDisplay = String(bounded[..<opening])
        } else {
            // Without angle brackets, accept only a bare mailbox. This avoids
            // trusting an email-looking display name before the real address.
            candidate = bounded
            rawDisplay = ""
        }
        let pattern = #"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: candidate,
                range: NSRange(candidate.startIndex..., in: candidate)),
              let range = Range(match.range, in: candidate),
              range == candidate.startIndex..<candidate.endIndex else { return nil }

        let address = candidate
        guard address.count <= ExternalMessageSource.maximumIdentityCharacters,
              let at = address.lastIndex(of: "@") else { return nil }
        let local = String(address[..<at])
        guard !local.isEmpty, local.count <= 64,
              let domain = MessageTrustPolicy.canonicalDomain(
                String(address[address.index(after: at)...])) else { return nil }

        // Preserve local-part case: SMTP permits case-sensitive local parts.
        let canonicalAddress = local + "@" + domain
        var display = rawDisplay
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty { display = canonicalAddress }
        display = MessageTrustPolicy.singleLine(display)
        return EmailSenderIdentity(
            address: canonicalAddress,
            domain: domain,
            displayName: display)
    }
}

public enum TrustedMessageSourceKind: String, Sendable, Codable, CaseIterable {
    case emailAddress
    case emailDomain
    case notificationSender
}

public enum MessageTrustPolicy {
    /// Domain-wide approval is intentionally unavailable for shared consumer
    /// mailbox providers. Approving t-online.de, for example, would approve
    /// every t-online customer rather than one known contact.
    public static let broadMailboxDomains: Set<String> = [
        "aol.com", "freenet.de", "gmail.com", "googlemail.com", "gmx.com",
        "gmx.de", "gmx.net", "hotmail.com", "icloud.com", "live.com",
        "mail.com", "mailbox.org", "mac.com", "me.com", "outlook.com",
        "posteo.de", "proton.me", "protonmail.com", "t-online.de", "web.de",
        "yahoo.com", "yahoo.de"
    ]

    public static func isBroadMailboxDomain(_ value: String) -> Bool {
        guard let domain = canonicalDomain(value) else { return true }
        return broadMailboxDomains.contains(domain)
    }

    /// Exact ASCII DNS normalization. Unicode/lookalike domains are kept out
    /// of approval until a trustworthy IDNA implementation is introduced.
    public static func canonicalDomain(_ value: String) -> String? {
        let domain = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        guard !domain.isEmpty, domain.count <= 253,
              domain.unicodeScalars.allSatisfy({ $0.isASCII }) else { return nil }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else { return nil }
        }
        return domain
    }

    public static func canonicalEmailAddress(_ value: String) -> String? {
        EmailSenderIdentity.parse(value)?.address
    }

    public static func normalizedNotificationLabel(_ value: String) -> String {
        String(singleLine(value).lowercased().prefix(
            ExternalMessageSource.maximumIdentityCharacters))
    }

    public static func singleLine(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Notifications (especially Telegram) auto-link URL-looking text. Strip
    /// links from proactive previews so a mail cannot manufacture a trusted-
    /// looking clickable path; the original stays in Mail.app.
    public static func phishingSafePreview(_ value: String, limit: Int = 1_000) -> String {
        let bounded = String(singleLine(value).prefix(max(0, limit)))
        let pattern = #"(?i)\b(?:https?://|www\.)\S+"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return bounded
        }
        return expression.stringByReplacingMatches(
            in: bounded,
            range: NSRange(bounded.startIndex..., in: bounded),
            withTemplate: "[link removed]")
    }

    /// External messages may propose a date or task, but must not smuggle a
    /// phishing destination into the resulting calendar/reminder suggestion.
    public static func containsURLLikeText(_ value: String) -> Bool {
        let pattern = #"(?i)(?:\b[a-z][a-z0-9+.-]{0,31}://|\b(?:mailto|data|javascript):|\bwww\.)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return true
        }
        return expression.firstMatch(
            in: value,
            range: NSRange(value.startIndex..., in: value)) != nil
    }
}
