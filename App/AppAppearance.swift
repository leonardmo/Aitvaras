import AppKit
import SwiftUI
import Observation
import AitvarasCore

/// App-wide appearance inheritance also covers separately hosted capture and
/// companion panels. No polling or duplicate per-window theme preferences.
@MainActor @Observable
final class AppAppearance {
    static let shared = AppAppearance()
    private(set) var mode = AppAppearanceMode.load()

    func select(_ mode: AppAppearanceMode) {
        self.mode = mode
        mode.save()
        apply()
    }

    func apply() {
        let override: NSAppearance?
        switch mode {
        case .system: override = nil
        case .light: override = NSAppearance(named: .aqua)
        case .dark: override = NSAppearance(named: .darkAqua)
        }
        NSApp.appearance = override
        // Explicitly update existing windows too. AppKit can otherwise retain
        // the previous effective appearance in an already hosted SwiftUI view.
        // New windows inherit the app override; System clears both levels.
        for window in NSApp.windows { window.appearance = override }
    }
}

struct AppearanceQuickControl: View {
    @State private var appearance = AppAppearance.shared

    var body: some View {
        Menu {
            ForEach(AppAppearanceMode.allCases) { mode in
                Button { appearance.select(mode) } label: {
                    Label(mode.title, systemImage: appearance.mode == mode ? "checkmark" : icon(for: mode))
                }
            }
        } label: {
            Image(systemName: icon(for: appearance.mode))
                .font(.system(size: 15, weight: .medium))
                .frame(width: 30, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Appearance: \(appearance.mode.title)")
        .accessibilityLabel("Appearance: \(appearance.mode.title). Choose Light, Dark or System.")
    }

    private func icon(for mode: AppAppearanceMode) -> String {
        switch mode {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }
}
