import Foundation
import Testing
import AitvarasCore
import AitvarasStore

@Suite struct MessageTrustTests {
    @Test func mailSenderParsingUsesExactAddressAndCanonicalDomain() {
        let source = ExternalMessageSource.email(
            senderHeader: #"Alice Example <Alice.Team@Example.COM>"#)

        #expect(source.kind == .email)
        #expect(source.identity == "Alice.Team@example.com")
        #expect(source.domain == "example.com")
        #expect(source.displayName.contains("Alice Example"))
        #expect(source.canApproveExactSender)
    }

    @Test func ambiguousAndUnicodeMailIdentitiesFailClosed() {
        let missing = ExternalMessageSource.email(senderHeader: "Bank Support")
        let unicode = ExternalMessageSource.email(
            senderHeader: "Support <person@exämple.org>")

        #expect(!missing.canApproveExactSender)
        #expect(missing.identity.hasPrefix("unparseable:"))
        #expect(!unicode.canApproveExactSender)
        #expect(unicode.domain == nil)
    }

    @Test func emailLookingDisplayNameCannotOverrideAngleBracketMailbox() {
        let source = ExternalMessageSource.email(
            senderHeader: #"friend@example.org <attacker@evil.test>"#)

        #expect(source.identity == "attacker@evil.test")
        #expect(source.domain == "evil.test")
        #expect(source.displayName == "friend@example.org")
    }

    @Test func proactivePreviewsRemoveClickableWebLinks() {
        let preview = MessageTrustPolicy.phishingSafePreview(
            "Urgent: open https://evil.test/steal?q=secret or www.evil.test now")

        #expect(!preview.contains("https://"))
        #expect(!preview.contains("www.evil.test"))
        #expect(preview == "Urgent: open [link removed] or [link removed] now")
    }

    @Test func URLLikeTextIsRecognizedForExternalActionBlocking() {
        #expect(MessageTrustPolicy.containsURLLikeText(
            #"{"notes":"Open https://evil.test/steal"}"#))
        #expect(MessageTrustPolicy.containsURLLikeText(
            #"{"notes":"Open custom+app://danger"}"#))
        #expect(MessageTrustPolicy.containsURLLikeText(
            #"{"notes":"Open data:text/html,danger"}"#))
        #expect(MessageTrustPolicy.containsURLLikeText(
            #"{"notes":"Visit www.evil.test"}"#))
        #expect(!MessageTrustPolicy.containsURLLikeText(
            #"{"title":"Submit report","dueISO":"2026-07-18T12:00:00Z"}"#))
    }

    @Test func sharedMailboxDomainsCannotBeApprovedAsDomains() throws {
        let stores = try inMemoryStores()
        // A real shared provider is the point of this test; addresses are
        // built from it so no real-looking address appears in the source.
        let provider = "gmx.de"

        #expect(MessageTrustPolicy.isBroadMailboxDomain("GMX.DE"))
        #expect(MessageTrustPolicy.isBroadMailboxDomain("gmail.com"))
        #expect(!MessageTrustPolicy.isBroadMailboxDomain("example.org"))
        #expect(throws: AitvarasStoreError.self) {
            try stores.trustMessageSource(
                kind: .emailDomain, value: provider, label: "GMX")
        }

        _ = try stores.trustMessageSource(
            kind: .emailAddress,
            value: "known.person@\(provider)",
            label: "Known person")
        #expect(try stores.isApprovedMessageSource(.email(
            senderHeader: "Known <known.person@\(provider)>")))
        #expect(!(try stores.isApprovedMessageSource(.email(
            senderHeader: "Phisher <other.person@\(provider)>"))))
    }

    @Test func domainApprovalIsExactAndDoesNotMatchSuffixTricks() throws {
        let stores = try inMemoryStores()
        _ = try stores.trustMessageSource(
            kind: .emailDomain, value: "example.org", label: "Example Org")

        #expect(try stores.isApprovedMessageSource(.email(
            senderHeader: "Person <person@example.org>")))
        #expect(!(try stores.isApprovedMessageSource(.email(
            senderHeader: "Fake <person@example.org.evil.test>"))))
        #expect(!(try stores.isApprovedMessageSource(.email(
            senderHeader: "Subdomain <person@mail.example.org>"))))
    }

    @Test func notificationApprovalIsScopedToExactAppAndLabel() throws {
        let stores = try inMemoryStores()
        let approved = ExternalMessageSource.notification(
            applicationID: "app.chat.one",
            applicationName: "Chat",
            senderLabel: "Alice")
        _ = try stores.trustMessageSource(
            kind: .notificationSender,
            value: approved.identity,
            applicationID: approved.applicationID,
            label: approved.displayName)

        #expect(try stores.isApprovedMessageSource(approved))
        #expect(!(try stores.isApprovedMessageSource(.notification(
            applicationID: "app.chat.two",
            applicationName: "Other chat",
            senderLabel: "Alice"))))
        #expect(!(try stores.isApprovedMessageSource(.notification(
            applicationID: "app.chat.one",
            applicationName: "Chat",
            senderLabel: "Alice Support"))))
    }

    @Test func unknownSenderObservationCommitsWithIncomingEventExactlyOnce() throws {
        let stores = try inMemoryStores()
        let source = ExternalMessageSource.email(
            senderHeader: "Unknown <unknown@example.org>")
        let observation = try #require(MessageSourceObservation(
            connectorID: "mail", source: source))
        let root = ActivityEvent(
            kind: .eventReceived,
            connectorID: "mail",
            summary: "Held mail from Unknown",
            sourceID: "mail:message-1")

        #expect(try stores.recordIncoming(
            root,
            seenConnectorID: "mail",
            itemID: "message-1",
            observing: observation) != nil)
        #expect(try stores.recordIncoming(
            root,
            seenConnectorID: "mail",
            itemID: "message-1",
            observing: observation) == nil)

        let pending = try stores.pendingMessageSourceObservations()
        #expect(pending.count == 1)
        #expect(pending[0].value == "unknown@example.org")
        #expect(pending[0].messageCount == 1)

        let next = ActivityEvent(
            kind: .eventReceived,
            connectorID: "mail",
            summary: "Held mail from Unknown",
            sourceID: "mail:message-2")
        #expect(try stores.recordIncoming(
            next,
            seenConnectorID: "mail",
            itemID: "message-2",
            observing: observation) != nil)
        #expect(try stores.pendingMessageSourceObservations()[0].messageCount == 2)
    }

    @Test func observationRollsBackWhenIncomingAuditCannotCommit() throws {
        let stores = try inMemoryStores()
        let source = ExternalMessageSource.email(
            senderHeader: "Unknown <unknown@example.org>")
        let observation = try #require(MessageSourceObservation(
            connectorID: "mail", source: source))
        try stores.db.queue.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_incoming_trust_test
                BEFORE INSERT ON seenItem
                BEGIN
                    SELECT RAISE(ABORT, 'injected failure');
                END
                """)
        }

        #expect(throws: (any Error).self) {
            try stores.recordIncoming(
                ActivityEvent(
                    kind: .eventReceived,
                    connectorID: "mail",
                    summary: "held",
                    sourceID: "mail:failed"),
                seenConnectorID: "mail",
                itemID: "failed",
                observing: observation)
        }
        #expect(try stores.pendingMessageSourceObservations().isEmpty)
        #expect(try stores.recentActivity().isEmpty)
    }

    @Test func trustingObservationRemovesItFromReviewQueue() throws {
        let stores = try inMemoryStores()
        let source = ExternalMessageSource.email(
            senderHeader: "Known <known@example.org>")
        let observation = try #require(MessageSourceObservation(
            connectorID: "mail", source: source))
        _ = try stores.recordIncoming(
            ActivityEvent(
                kind: .eventReceived,
                connectorID: "mail",
                summary: "held",
                sourceID: "mail:known"),
            seenConnectorID: "mail",
            itemID: "known",
            observing: observation)

        _ = try stores.trustMessageSource(
            kind: .emailAddress,
            value: observation.value,
            label: observation.displayName)

        #expect(try stores.pendingMessageSourceObservations().isEmpty)
        #expect(try stores.isApprovedMessageSource(source))
    }

    @Test func removingTrustedSourceRevokesApproval() throws {
        let stores = try inMemoryStores()
        let source = ExternalMessageSource.email(
            senderHeader: "Known <known@example.org>")
        let trusted = try stores.trustMessageSource(
            kind: .emailAddress,
            value: "known@example.org",
            label: "Known")

        #expect(try stores.isApprovedMessageSource(source))
        try stores.removeTrustedMessageSource(trusted.id)
        #expect(!(try stores.isApprovedMessageSource(source)))
    }

    @Test func dismissedSourceReturnsWhenAnotherMessageArrives() throws {
        let stores = try inMemoryStores()
        let source = ExternalMessageSource.email(
            senderHeader: "Unknown <unknown@example.org>")
        let observation = try #require(MessageSourceObservation(
            connectorID: "mail", source: source))
        _ = try stores.recordIncoming(
            ActivityEvent(
                kind: .eventReceived,
                connectorID: "mail",
                summary: "held",
                sourceID: "mail:first"),
            seenConnectorID: "mail",
            itemID: "first",
            observing: observation)

        let first = try #require(stores.pendingMessageSourceObservations().first)
        try stores.dismissMessageSourceObservation(first.id)
        #expect(try stores.pendingMessageSourceObservations().isEmpty)

        _ = try stores.recordIncoming(
            ActivityEvent(
                kind: .eventReceived,
                connectorID: "mail",
                summary: "held",
                sourceID: "mail:second"),
            seenConnectorID: "mail",
            itemID: "second",
            observing: observation)

        let returned = try #require(stores.pendingMessageSourceObservations().first)
        #expect(returned.id == first.id)
        #expect(returned.messageCount == 2)
    }
}
