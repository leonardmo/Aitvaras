import Foundation

enum SetupPage: String, CaseIterable, Identifiable {
    case overview, models, capture, cloud, voice, avatar, access, memory, usage
    var id: String { rawValue }
    var label: String { self == .avatar ? "Companion" : rawValue.capitalized }
    var title: String {
        switch self {
        case .overview: "Make Aitvaras yours"
        case .models: "Local intelligence"
        case .capture: "Capture & transcription"
        case .cloud: "Cloud agents & privacy"
        case .voice: "Voice conversations"
        case .avatar: "Your companion"
        case .access: "Permissions & access"
        case .memory: "Memory schedule"
        case .usage: "Usage & history"
        }
    }
    var detail: String {
        switch self {
        case .overview: "Start with a local model. Everything else can be added when you need it."
        case .models: "Download a model and choose which local model handles each kind of task."
        case .capture: "Choose the capture language, check on-device speech assets and control local postprocessing."
        case .cloud: "Choose which features may use a cloud provider, and see what they send."
        case .voice: "Set up listening and speaking separately. Voice is optional."
        case .avatar: "Choose a character or a minimal overlay without an avatar."
        case .access: "Only grant access for features you want to use. None is required for typed chat."
        case .memory: "Choose when saved conversations are consolidated into long-term memory."
        case .usage: "Review local and cloud activity. Usage records stay in your local profile."
        }
    }
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .models: "cpu"
        case .capture: "record.circle"
        case .cloud: "lock.shield"
        case .voice: "waveform"
        case .avatar: "flame"
        case .access: "hand.raised"
        case .memory: "clock.arrow.circlepath"
        case .usage: "chart.bar"
        }
    }
}
