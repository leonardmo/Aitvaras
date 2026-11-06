// Minimal diagnostic host for the real app renderer. Deliberately excludes
// AI engines, connectors, microphones, databases and the user's preferences.
import AppKit
import Observation
import AitvarasCore

@Observable @MainActor final class AppModel {
    var characterState: CharacterState = .idle
    var mouthLevel: Float = 0
}

enum AvatarStyle: String { case human, creature }
enum AvatarLocator {
    static var style: AvatarStyle {
        AvatarStyle(rawValue: ProcessInfo.processInfo.environment["AITVARAS_AVATAR_STYLE"] ?? "creature") ?? .creature
    }
    static var effectiveAvatarURL: URL? {
        Bundle.main.url(forResource: "AitvarasAvatar", withExtension: "glb")
    }
}
extension Notification.Name {
    static let aitvarasAvatarChanged = Notification.Name("aitvarasAvatarChanged")
    static let aitvarasMailArrived = Notification.Name("aitvarasMailArrived")
}

@main struct AvatarRendererDiagnosticApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            if let path = AvatarEfficiencyCheck.requestedPath { await AvatarEfficiencyCheck.run(path: path) }
            if let path = AvatarShot.requestedPath { await AvatarShot.run(path: path) }
            if let path = AvatarShot.liveshotPath { await AvatarShot.runLive(path: path) }
            print("Pass --avatar-efficiency-check, --avatarshot or --liveshot with an output path.")
            exit(2)
        }
        app.run()
    }
}
