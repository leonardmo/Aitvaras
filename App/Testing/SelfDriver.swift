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
            let surface = SelfDriveSurface(window: window)
            let results = try await SelfDriveRecorder.run(scenario, perform: { step in
                if let delay = step.delay { try await Task.sleep(for: .seconds(delay)) }
                return try await surface.perform(step, directory: directory)
            }, checkpoint: save)
            NSApp.terminate(nil)
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
            NSApp.terminate(nil)
        }
    }
}

@MainActor private final class SelfDriveWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

#endif
