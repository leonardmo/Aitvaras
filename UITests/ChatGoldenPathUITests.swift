import XCTest

/// Real clicks, real window screenshots, real CLIs in a throwaway profile. Everything
/// runs in one test so one macOS approval covers it, and failures don't stop the rest.
@MainActor
final class ChatGoldenPathUITests: XCTestCase {
    private var app: XCUIApplication!

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func dump(_ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func shot(_ name: String) { E2EApp.screenshot(app, named: name, in: self) }

    private func transcriptShows(_ text: String, timeout: TimeInterval, caseSensitive: Bool = false) -> Bool {
        let comparison = caseSensitive ? "CONTAINS" : "CONTAINS[c]"
        let predicate = NSPredicate(format: "label \(comparison) %@ OR value \(comparison) %@", text, text)
        return element("chat.transcript").descendants(matching: .any).matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    private func send(_ text: String) {
        let input = element("chat.composer.input")
        XCTAssertTrue(input.waitForExistence(timeout: 10), "composer input")
        guard input.exists else { return }
        input.click()
        input.typeText(text)
        if element("chat.composer.send").exists { element("chat.composer.send").click() }
    }

    private func selectProvider(_ provider: String) {
        let picker = element("chat.agent")
        guard picker.waitForExistence(timeout: 10), picker.isEnabled else {
            XCTFail("Agent picker is unavailable")
            return
        }
        picker.click()
        let choice = element("chat.provider.\(provider)")
        guard choice.waitForExistence(timeout: 10) else {
            XCTFail("Provider is missing from the Agent picker")
            return
        }
        choice.click()
        element("chat.agent.done").click()
    }

    private func configureProviders() throws {
        let settings = element("gearshape")
        XCTAssertTrue(settings.waitForExistence(timeout: 15))
        settings.click()
        element("settings.providers").click()
        for (title, id) in [("Claude", "claude"), ("Codex", "codex"), ("Local", "local")] {
            element("chat.settings.addProvider").click()
            let kind = element("chat.settings.providerKind")
            XCTAssertTrue(kind.waitForExistence(timeout: 10))
            if id != "claude" {
                kind.click()
                app.menuItems[title].firstMatch.click()
            }
            if id != "local" { element("chat.settings.useDefaultCLI").click() }
            element("chat.settings.confirmAddProvider").click()
            XCTAssertTrue(element("chat.settings.\(id)").waitForExistence(timeout: 10))
        }
    }

    func testGoldenPath() throws {
        continueAfterFailure = true
        app = E2EApp.launch(environment: ["AITVARAS_AGENT_TEST_PROVIDERS": "real"])
        defer { app.terminate() }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        sleep(3)
        shot("01-launch")
        dump("01-launch-tree")

        try configureProviders()
        // The configured CLI accounts are now available in Chat.
        let nav = app.buttons["bubble.left.and.text.bubble.right"].firstMatch
        if nav.waitForExistence(timeout: 10) { nav.click() }
        sleep(2)
        shot("02-chat-empty")
        dump("02-chat-tree")

        for id in ["chat.new", "chat.new.unassigned"] where element(id).exists {
            element(id).click()
            break
        }
        sleep(2)
        shot("03-new-chat")
        dump("03-new-chat-tree")

        guard element("chat.composer.input").waitForExistence(timeout: 10) else {
            XCTFail("No composer after opening a new chat")
            return
        }

        // Claude: a real reply through the real login.
        selectProvider("claude")
        sleep(2)
        shot("04-claude-selected")
        send("Reply with only this word spelled backwards: nacilep")
        sleep(2)
        shot("05-claude-streaming")
        XCTAssertTrue(transcriptShows("pelican", timeout: 90), "Claude reply")
        sleep(3)
        shot("06-claude-replied")
        dump("06-claude-tree")

        // Codex can continue with the earlier conversation.
        selectProvider("codex")
        sleep(2)
        shot("07-codex-selected")
        send("Which word did you just reply with? Reply with only that word, in capitals.")
        XCTAssertTrue(transcriptShows("PELICAN", timeout: 120, caseSensitive: true), "Codex catch-up")
        sleep(3)
        shot("08-codex-replied")

        // A shell command in Ask mode should show exactly one card.
        send("Run this exact shell command and nothing else: touch e2e-made.txt")
        let allow = element("chat.request.0.allow")
        XCTAssertTrue(allow.waitForExistence(timeout: 120), "approval card")
        shot("09-approval-card")
        dump("09-approval-tree")
        XCTAssertFalse(element("chat.request.1.allow").exists, "only one card")
        if allow.exists { allow.click() }
        sleep(15)
        shot("10-after-approval")

        // Stop mid-stream.
        send("Write a 400 word story about a dragon.")
        let stop = element("chat.stop")
        if stop.waitForExistence(timeout: 30) {
            shot("11-running")
            stop.click()
        }
        sleep(5)
        shot("12-stopped")

        selectProvider("local")
        sleep(2)
        shot("13-local-selected")

        for menu in ["chat.agent", "chat.mode"] where element(menu).exists {
            element(menu).click()
            sleep(1)
            shot("14-menu-\(menu)")
            app.typeKey(.escape, modifierFlags: [])
            sleep(1)
        }

        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        shot("15-settings")
        let providers = app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] 'Providers'")).firstMatch
        if providers.exists { providers.click() }
        sleep(2)
        shot("16-settings-providers")
        dump("16-settings-tree")
    }
}
