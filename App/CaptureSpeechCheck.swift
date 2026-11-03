import Foundation
@preconcurrency import AVFoundation
import Speech
import AitvarasCore
import AitvarasVoice

/// Explicit, bootstrap-free diagnostic. The caller supplies synthetic German
/// speech; this path never opens a microphone, requests authorization, installs
/// assets, or prints recognized words.
enum CaptureSpeechCheck {
    private struct Counts: Sendable {
        var updates = 0
        var finalResults = 0
        var finalCharacters = 0
        var errorCode: String?
    }

    private struct Completion: Sendable {
        let stop: TranscriberSession.StopResult
        let counts: Counts
    }

    static func run(path: String) async -> Never {
        guard AitvarasPaths.isIsolated,
              ProcessInfo.processInfo.environment["AITVARAS_UI_TEST_MODE"] == "1" else {
            finish("FAIL isolated profile and AITVARAS_UI_TEST_MODE=1 are required", code: 1)
        }

        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de-DE")) else {
            finish("SKIP German on-device speech recognition is unavailable; no assets were downloaded", code: 0)
        }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier == supported.identifier }) else {
            finish("SKIP German speech assets are not installed; no assets were downloaded", code: 0)
        }

        let session = TranscriberSession()
        var consumer: Task<Counts, Never>?
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
            let format = file.processingFormat
            let duration = Double(file.length) / format.sampleRate
            guard file.length > 0, duration.isFinite, duration > 0, duration <= 120 else {
                finish("FAIL synthetic audio must contain between 0 and 120 seconds of PCM-readable audio", code: 1)
            }

            print("CAPTURE_SPEECH_STOP_CHECK BEGIN installed=de-DE inputSeconds=\(String(format: "%.2f", duration)) downloads=disabled microphone=unused")
            let updates = try await session.start(
                locale: Locale(identifier: "de-DE"), micFormat: format, allowDownload: false)
            let resultConsumer = Task {
                var counts = Counts()
                do {
                    for try await update in updates {
                        counts.updates += 1
                        if update.isFinal && !update.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            counts.finalResults += 1
                            counts.finalCharacters += update.text.count
                        }
                    }
                } catch {
                    counts.errorCode = safeErrorCode(error)
                }
                return counts
            }
            consumer = resultConsumer

            var buffers = 0
            while file.framePosition < file.length {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                    throw NSError(domain: "Aitvaras.CaptureSpeechCheck", code: 1)
                }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                buffers += 1
                await session.feed(handoff: .init(buffer: buffer))
            }

            let stoppedAt = ProcessInfo.processInfo.systemUptime
            let completion = try await AsyncDeadline.run(for: .seconds(15)) {
                let stopped = await session.stop(finalizing: true)
                let counts = await resultConsumer.value
                return Completion(stop: stopped, counts: counts)
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - stoppedAt
            guard completion.stop.finalized,
                  completion.counts.errorCode == nil,
                  completion.counts.finalResults > 0,
                  elapsed < 15 else {
                finish("FAIL finalized=\(completion.stop.finalized) finalResults=\(completion.counts.finalResults) updates=\(completion.counts.updates) stopSeconds=\(String(format: "%.3f", elapsed)) backend=\(completion.counts.errorCode ?? "none")", code: 1)
            }
            finish("PASS finalized=true finalResults=\(completion.counts.finalResults) finalCharacters=\(completion.counts.finalCharacters) updates=\(completion.counts.updates) buffers=\(buffers) stopSeconds=\(String(format: "%.3f", elapsed))", code: 0)
        } catch is AsyncDeadline.Exceeded {
            consumer?.cancel()
            // Do not await a non-cooperative framework operation after the
            // deadline. Exiting quarantines this diagnostic-only session.
            finish("FAIL stop or result consumer exceeded the 15-second deadline", code: 1)
        } catch {
            consumer?.cancel()
            _ = try? await AsyncDeadline.run(for: .seconds(3)) {
                await session.stop(finalizing: false)
            }
            finish("FAIL backend=\(safeErrorCode(error))", code: 1)
        }
    }

    private static func safeErrorCode(_ error: any Error) -> String {
        let error = error as NSError
        return "\(error.domain):\(error.code)"
    }

    private static func finish(_ message: String, code: Int32) -> Never {
        print("CAPTURE_SPEECH_STOP_CHECK \(message)")
        exit(code)
    }
}
