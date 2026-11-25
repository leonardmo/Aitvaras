import SwiftUI
import AitvarasAgents

/// Flat, temporary controls for the current chat. Provider administration lives in Settings.
struct AgentComposerPicker: View {
    @Bindable var chat: ChatModel
    let iconOnly: Bool

    @State private var isPresented = false

    private var choiceTitle: String { chat.title(chat.choice) }
    private var effortAvailable: Bool { chat.provider != .local && !(chat.selectedModel?.efforts.isEmpty ?? true) }
    private var summary: String {
        guard chat.hasConfiguredProvider else {
            return chat.allChoices.isEmpty ? "Add Provider" : "Choose provider"
        }
        return ([choiceTitle, chat.modelTitle] + (effortAvailable ? [chat.effort.isEmpty ? "Default effort" : chat.effort.capitalized] : []))
            .joined(separator: " · ")
    }

    var body: some View {
        Button {
            if chat.allChoices.isEmpty { SettingsNavigation.open(.page(.providers)) }
            else { isPresented.toggle() }
        } label: {
            ComposerControlLabel(title: summary, icon: "cpu", iconOnly: iconOnly, maximumTitleWidth: 220)
        }
        .buttonStyle(.plain)
        .help(summary)
        .accessibilityLabel("Agent")
        .accessibilityValue(summary)
        .accessibilityIdentifier("chat.agent")
        .disabled(chat.isBusy || chat.creatingChat || chat.signingIn != nil)
        .popover(isPresented: $isPresented, arrowEdge: .top) { panel }
        .onChange(of: chat.composerOwnerID) { isPresented = false }
        .onChange(of: chat.isBusy) { _, busy in
            if busy { isPresented = false }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                profiles.frame(width: 150)
                Divider()
                modelChoices.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 216)
            if effortAvailable { effortChoices }
            Divider()
            HStack {
                Button {
                    isPresented = false
                    SettingsNavigation.open(.page(.providers))
                } label: {
                    Label("Provider Settings", systemImage: "gearshape")
                }
                .buttonStyle(.link)
                .accessibilityIdentifier("chat.agent.settings")
                Spacer()
                Button("Done") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("chat.agent.done")
            }
        }
        .padding(14)
        .frame(width: 422)
        .controlSize(.regular)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.agent.options")
    }

    private var profiles: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Provider", systemImage: "cpu").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(chat.allChoices.enumerated()), id: \.element.id) { index, choice in
                        providerRow(choice, index: index)
                    }
                }.frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.provider")
    }

    @ViewBuilder private func providerRow(_ choice: AgentProviderChoice, index: Int) -> some View {
        let row = ComposerPickerRow(title: chat.title(choice), subtitle: chat.statusLabel(choice),
                                    selected: chat.choice == choice, icon: icon(for: choice.provider)) {
            chat.setChoice(choice)
        }
        .accessibilityIdentifier("chat.provider.\(choice.id)")
        if index < 9 {
            row.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.control, .command])
        } else { row }
    }

    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Model", systemImage: "cube").font(.subheadline.weight(.semibold))
            if chat.models.isEmpty {
                Text(chat.modelTitle).font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(chat.models, id: \.id) { model in
                            ComposerPickerRow(title: chat.modelTitle(model), selected: chat.model == model.id) {
                                chat.model = model.id
                            }
                            .accessibilityIdentifier("chat.model.\(model.id)")
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(chat.modelTitle)
        .accessibilityIdentifier("chat.model")
    }

    private var effortChoices: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Effort", systemImage: "brain").font(.subheadline.weight(.semibold))
                .help("Higher effort gives a supported model more time to reason and can take longer.")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 4)], spacing: 4) {
                ForEach([""] + (chat.selectedModel?.efforts ?? []), id: \.self) { value in
                    let selected = chat.effort == value
                    Button { chat.effort = value } label: {
                        Text(value.isEmpty ? "Default" : value.capitalized)
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, minHeight: 26)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("chat.effort.\(value.isEmpty ? "default" : value)")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(chat.effort.isEmpty ? "Default" : chat.effort.capitalized)
        .accessibilityIdentifier("chat.effort")
    }

    private func icon(for provider: AgentProvider) -> String {
        switch provider {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .local: "desktopcomputer"
        }
    }
}

struct ComposerControlLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let icon: String
    let iconOnly: Bool
    var maximumTitleWidth: CGFloat? = nil

    var body: some View {
        let ink = colorScheme == .dark ? Color(white: 0.92) : Color(white: 0.15)
        HStack(spacing: 5) {
            Image(systemName: icon).foregroundStyle(ink.opacity(0.72))
                .frame(width: 16, height: 16)
            if !iconOnly {
                ViewThatFits(in: .horizontal) {
                    Text(title).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                    Text(title).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: maximumTitleWidth, alignment: .leading)
                .foregroundStyle(ink)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.66))
            }
        }
        .font(.caption)
        .padding(.horizontal, iconOnly ? 5 : 8)
        .frame(minHeight: 26)
        .background(ink.opacity(0.05), in: Capsule())
        .contentShape(.rect)
    }
}

struct ComposerPickerRow: View {
    let title: String
    var subtitle: String? = nil
    let selected: Bool
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).frame(width: 16).foregroundStyle(.secondary) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").font(.caption2).foregroundStyle(Color.accentColor) }
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(minHeight: 27)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }
}
