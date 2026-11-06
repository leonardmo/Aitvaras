#if DEBUG
import AppKit
import SwiftUI
import AitvarasCore

/// No AXUIElement client, event posting, screen capture or system automation.
/// All objects and events belong to the single window created here.
@MainActor enum SelfDriver {
    static var requested: Bool { ProcessInfo.processInfo.environment["AITVARAS_SELF_DRIVE"] != nil }

    /// Called before SwiftUI can present its normal scene. Prohibited activation
    /// plus a nonactivating panel prevents even an accidental key-window request.
    static func prepareLaunch() {
        NSApp.setActivationPolicy(.prohibited)
        // SwiftUI builds its accessibility tree only once an assistive client asks for it.
        // This asks from inside, for this process alone, with no system permission.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    /// Normal delegate shutdown runs first, but a test run must always end.
    private static func finish() {
        Task.detached { try? await Task.sleep(for: .seconds(10)); exit(0) }
        NSApp.terminate(nil)
    }

    static func run() async {
        let env = ProcessInfo.processInfo.environment
        guard let output = env["AITVARAS_SELF_DRIVE_OUTPUT"], !output.isEmpty else {
            FileHandle.standardError.write(Data("Self-drive requires AITVARAS_SELF_DRIVE_OUTPUT\n".utf8))
            exit(1)
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        func save(_ results: [SelfDriveResult]) throws {
            try encoder.encode(results).write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard AitvarasPaths.isIsolated, env["AITVARAS_DISABLE_EXTERNAL_INTEGRATIONS"] == "1" else {
                throw SelfDriveFailure("Self-drive requires an isolated state directory and disabled external integrations")
            }
            guard let path = env["AITVARAS_SELF_DRIVE"], !path.isEmpty else {
                throw SelfDriveFailure("Missing scenario path")
            }
            let scenario = try SelfDriveScenario.parse(Data(contentsOf: URL(fileURLWithPath: path)))
            let window = SelfDriveWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                                         styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.hidesOnDeactivate = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: MainWindow().environment(AppModel.shared))
            window.orderFront(nil) // Never makeKey, activate or orderFrontRegardless.
            await AppModel.shared.bootstrapIfNeeded()
            if let model = env["AITVARAS_SELF_DRIVE_CODEX_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
                AppModel.shared.chatModel?.selfDriveCodexModel = model
            }
            if let folder = env["AITVARAS_SELF_DRIVE_PROJECT"] {
                var isDirectory: ObjCBool = false
                guard folder.hasPrefix("/"), FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory), isDirectory.boolValue,
                      AppModel.shared.createWorkspaceProject(title: "Self-drive project", instructions: "",
                          folderURLs: [URL(fileURLWithPath: folder, isDirectory: true)]) else {
                    throw SelfDriveFailure("Self-drive project folder is unavailable")
                }
                AppModel.shared.startNewAgentChat(projectID: AppModel.shared.selectedWorkspaceProjectID)
            }
            let projectID = AppModel.shared.chatModel?.newProjectID
            var chats: [UUID] = []
            func resolve(_ identifier: String?) throws -> String? {
                guard var identifier else { return nil }
                if identifier.contains("$project") {
                    guard let projectID else { throw SelfDriveFailure("No self-drive project") }
                    identifier = identifier.replacingOccurrences(of: "$project", with: projectID.uuidString)
                }
                for number in (1...20).reversed() where identifier.contains("$chat\(number)") {
                    guard chats.count >= number else { throw SelfDriveFailure("Chat reference has not been created by the scenario") }
                    identifier = identifier.replacingOccurrences(of: "$chat\(number)", with: chats[number - 1].uuidString)
                }
                return identifier
            }
            let surface = SelfDriveSurface(window: window)
            let results = try await SelfDriveRecorder.run(scenario, perform: { step in
                if let delay = step.delay { try await Task.sleep(for: .seconds(delay)) }
                var resolved = step
                resolved.identifier = try resolve(step.identifier)
                resolved.within = try resolve(step.within)
                resolved.anyOf = try step.anyOf?.map { try resolve($0)! }
                let result = try await surface.perform(resolved, directory: directory)
                if let id = AppModel.shared.selectedWorkspaceChatID, !chats.contains(id) { chats.append(id) }
                return result
            }, checkpoint: save)
            finish()
            // Normal delegate shutdown remains responsible for provider cleanup.
            if results.contains(where: { $0.status == "failed" }) {
                FileHandle.standardError.write(Data("Self-drive completed with failed steps; inspect results.json\n".utf8))
            }
        } catch {
            // Setup errors have no scenario step. Keep them separate from the
            // one-entry-per-step report rather than inventing a scenario entry.
            if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("results.json").path) {
                try? save([])
            }
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("startup-error.txt"))
            FileHandle.standardError.write(Data("Self-drive setup failed; inspect startup-error.txt\n".utf8))
            finish()
        }
    }
}

@MainActor private final class SelfDriveWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

#endif
