import Foundation
import AitvarasCore
import AitvarasStore

/// Capture mode as agent tools (F12): "Aitvaras, schreib mit" always works.
/// `start_capture` only OPENS the setup panel — screen/audio scope and the
/// consent checkbox are chosen by the user there; recording never starts
/// from a model decision alone. Stopping and reading state are direct.
///
/// The app injects the actual controls at registration (the controller is
/// UI-side); without them the tools report capture as unavailable.
public actor CaptureConnector: Connector {
    public nonisolated let id = "capture"
    public nonisolated let displayName = "Capture"

    private let stores: Stores
    private var openSetup: (@Sendable () async -> Void)?
    private var stop: (@Sendable () async -> String)?
    private var status: (@Sendable () async -> String)?

    public init(stores: Stores) {
        self.stores = stores
    }

    /// Called by the app after the capture controller exists.
    public func attach(openSetup: @escaping @Sendable () async -> Void,
                       stop: @escaping @Sendable () async -> String,
                       status: @escaping @Sendable () async -> String) {
        self.openSetup = openSetup
        self.stop = stop
        self.status = status
    }

    public nonisolated let tools: [ToolDefinition] = [
        ToolDefinition(
            name: "start_capture",
            description: "Open the capture setup panel so the user can start transcribing a meeting, lecture, video or work session. The user picks what to capture (a window, the whole screen, or audio only) and confirms consent there — recording begins only after their confirmation. Use when the user says 'schreib mit', 'start capture', 'transcribe this meeting'.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "stop_capture",
            description: "End the running capture session. Transcription stops and a structured summary is produced. Use for 'stop recording', 'Aufnahme beenden', 'wir sind fertig'.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .reversibleWrite),
        ToolDefinition(
            name: "capture_status",
            description: "Whether a capture session is running, since when, and what it captures. Also lists recent finished captures with their summaries' first lines.",
            parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
            risk: .read)
    ]

    public func health() async -> ConnectorHealth { .ready }

    public func execute(toolName: String, argumentsJSON: String) async throws -> String {
        switch toolName {
        case "start_capture":
            guard let openSetup else {
                throw ConnectorError("Capture is not available in this session.")
            }
            await openSetup()
            return "Capture setup panel opened. The user now chooses what to capture (window / whole screen / audio only, and which audio) and confirms that recorded people agree. Tell the user briefly to complete the panel — do not claim recording has started."

        case "stop_capture":
            guard let stop else {
                throw ConnectorError("Capture is not available in this session.")
            }
            return await stop()

        case "capture_status":
            let live = await status?() ?? "No capture session running."
            let recent = (try? stores.captureRecords(limit: 3)) ?? []
            guard !recent.isEmpty else { return live }
            let lines = recent.map { record in
                let date = record.startedAt.formatted(date: .abbreviated, time: .shortened)
                let head = record.summaryPending
                    ? "summary pending"
                    : String(record.summary.split(separator: "\n").first { !$0.hasPrefix("#") && !$0.isEmpty } ?? "")
                return "- \(date) · \(record.title) (\(record.scope)): \(head)"
            }
            return live + "\n\nRecent captures:\n" + lines.joined(separator: "\n")

        default:
            throw ConnectorError("Unknown tool \(toolName)")
        }
    }

    public func events() -> AsyncStream<ConnectorEvent> {
        AsyncStream { $0.finish() }
    }
}
