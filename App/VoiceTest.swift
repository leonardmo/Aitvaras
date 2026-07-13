import Foundation
@preconcurrency import AVFoundation
import Speech
import AitvarasVoice

/// Voice pipeline diagnostics (`Aitvaras --voicetest`): checks permissions,
/// speech model availability, mic levels, and live transcription, with
/// every stage printed. Used to debug "listening but no reaction".
enum VoiceTest {
    static var requested: Bool {
        CommandLine.arguments.contains("--voicetest")
    }

    static func run() async -> Never {
        print("[voicetest] --- permissions ---")
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[voicetest] mic authorization: \(micStatus.rawValue) (\(describe(micStatus)))")
        if micStatus != .authorized {
            print("[voicetest] requesting mic access — CLICK THE PROMPT")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            print("[voicetest] mic granted: \(granted)")
        }
        let speechStatus = TranscriberSession.authorizationStatus()
        print("[voicetest] speech authorization: \(speechStatus.rawValue)")
        if speechStatus != .authorized {
            print("[voicetest] requesting speech recognition — CLICK THE PROMPT")
            let granted = await TranscriberSession.requestAuthorization()
            print("[voicetest] speech granted: \(granted)")
        }

        print("[voicetest] --- speech model ---")
        print("[voicetest] SpeechTranscriber.isAvailable: \(SpeechTranscriber.isAvailable)")
        let installed = await SpeechTranscriber.installedLocales
        print("[voicetest] installed locales: \(installed.map(\.identifier))")
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "de-DE"))
        print("[voicetest] de-DE supported as: \(supported?.identifier ?? "NOT SUPPORTED")")
        let start = Date()
        do {
            let ok = try await TranscriberSession.ensureModel(locale: Locale(identifier: "de-DE"))
            print("[voicetest] ensureModel(de-DE): \(ok) in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        } catch {
            print("[voicetest] ensureModel FAILED: \(error)")
        }

        print("[voicetest] --- microphone (3s capture) ---")
        let mic = MicCapture()
        do {
            let buffers = try mic.start()
            guard let format = mic.format else { throw NSError(domain: "vt", code: 1) }
            print("[voicetest] mic format: \(format.sampleRate) Hz, \(format.channelCount) ch")

            let transcriber = TranscriberSession()
            let updates = try await transcriber.start(locale: Locale(identifier: "de-DE"), micFormat: format)
            let reader = Task {
                do {
                    for try await update in updates {
                        print("[voicetest] \(update.isFinal ? "FINAL" : "partial"): \(update.text)")
                    }
                } catch {
                    print("[voicetest] transcriber stream ERROR: \(error)")
                }
            }

            print("[voicetest] --- capturing 15s: first 3s level check, then SPEAK GERMAN ---")
            var maxLevel: Float = -120
            var count = 0
            let deadline = Date().addingTimeInterval(15)
            var levelReported = false
            for await buffer in buffers {
                maxLevel = max(maxLevel, MicCapture.level(of: buffer))
                count += 1
                await transcriber.feed(buffer)
                if !levelReported, count > 0, Date().timeIntervalSince(deadline) > -12 {
                    print("[voicetest] buffers: \(count), peak: \(String(format: "%.1f", maxLevel)) dBFS \(maxLevel < -70 ? "← SILENCE, mic not delivering" : "← audio flowing") — keep speaking…")
                    levelReported = true
                }
                if Date() > deadline { break }
            }
            try? await Task.sleep(for: .seconds(2))   // let final results land
            reader.cancel()
            await transcriber.stop()
            mic.stop()
            print("[voicetest] total buffers: \(count), peak: \(String(format: "%.1f", maxLevel)) dBFS")
            print("[voicetest] done")
        } catch {
            print("[voicetest] mic FAILED: \(error)")
        }
        exit(0)
    }

    private static func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "DENIED — enable in System Settings → Privacy → Microphone"
        case .restricted: "restricted"
        case .notDetermined: "not asked yet"
        @unknown default: "unknown"
        }
    }
}
