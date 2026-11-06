#if DEBUG
import Foundation

/// Debug-only wire format shared by the in-process driver and package tests.
public struct SelfDriveScenario: Decodable, Sendable {
    public let steps: [SelfDriveStep]

    public static func parse(_ data: Data) throws -> SelfDriveScenario {
        let scenario = try JSONDecoder().decode(Self.self, from: data)
        for step in scenario.steps { try step.validate() }
        return scenario
    }
}

public struct SelfDriveStep: Codable, Sendable {
    public enum Action: String, Codable, Sendable { case press, type, waitFor, screenshot, dumpTree }
    public let action: Action
    public let identifier: String?
    public let text: String?
    public let name: String?
    public let timeout: Double?
    /// Settling time before this step, replacing the golden path's sleeps.
    public let delay: Double?
    /// Used for assertions such as "there is no second approval card".
    public let absent: Bool?

    private func invalid(_ reason: String) -> SelfDriveFailure { .init(reason) }
    public func validate() throws {
        for value in [timeout, delay].compactMap({ $0 }) {
            guard value.isFinite, value >= 0, value <= 300 else { throw invalid("Invalid time interval") }
        }
        switch action {
        case .press:
            guard identifier?.isEmpty == false else { throw invalid("press needs an identifier") }
        case .type:
            guard text != nil else { throw invalid("type needs text") }
        case .waitFor:
            guard (identifier?.isEmpty == false) != (text?.isEmpty == false) else {
                throw invalid("waitFor needs exactly one identifier or text")
            }
        case .screenshot, .dumpTree:
            guard let name, !name.isEmpty, name != ".", name != "..",
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }) else {
                throw invalid("Artifact name must be a single safe filename")
            }
        }
    }
}

public struct SelfDriveFailure: Error, LocalizedError, Sendable {
    public let reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

public struct SelfDriveResult: Codable, Sendable {
    public let index: Int
    public let action: String
    public let status: String
    public let reason: String
}

/// A failure is recorded without aborting subsequent steps. Checkpoint after each
/// step so a later crash still leaves a useful partial report.
@MainActor public enum SelfDriveRecorder {
    public static func run(
        _ scenario: SelfDriveScenario,
        perform: (SelfDriveStep) async throws -> String,
        checkpoint: ([SelfDriveResult]) throws -> Void
    ) async throws -> [SelfDriveResult] {
        var results: [SelfDriveResult] = []
        try checkpoint(results)
        for (index, step) in scenario.steps.enumerated() {
            let result: SelfDriveResult
            do {
                result = SelfDriveResult(index: index, action: step.action.rawValue,
                                         status: "passed", reason: try await perform(step))
            } catch {
                result = SelfDriveResult(index: index, action: step.action.rawValue,
                                         status: "failed", reason: error.localizedDescription)
            }
            results.append(result)
            try checkpoint(results)
        }
        return results
    }
}
#endif
