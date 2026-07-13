import Foundation
import AVFoundation
import Speech

/// Offline transcription of a WAV file (`Aitvaras --transcribefile x.wav`):
/// verifies the SpeechAnalyzer + model against captured audio without
/// touching the microphone (which CLI contexts aren't allowed to).
enum FileTranscribe {
    static var requestedPath: String? {
        guard let idx = CommandLine.arguments.firstIndex(of: "--transcribefile"),
              CommandLine.arguments.count > idx + 1 else { return nil }
        return CommandLine.arguments[idx + 1]
    }

    static func run(path: String) async -> Never {
        do {
            let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: "de-DE")) ?? Locale(identifier: "de-DE")
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults],
                attributeOptions: [])
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            print("[transcribefile] \(path): \(file.processingFormat.sampleRate)Hz \(file.processingFormat.channelCount)ch, \(Double(file.length) / file.processingFormat.sampleRate)s")
            let analyzer = try await SpeechAnalyzer(
                inputAudioFile: file, modules: [transcriber], finishAfterFile: true)
            var got = 0
            for try await result in transcriber.results {
                got += 1
                print("[transcribefile] \(result.isFinal ? "FINAL" : "partial"): \(String(result.text.characters))")
            }
            _ = analyzer
            print("[transcribefile] done, \(got) results")
            exit(got > 0 ? 0 : 1)
        } catch {
            print("[transcribefile] ERROR: \(error)")
            exit(2)
        }
    }
}
