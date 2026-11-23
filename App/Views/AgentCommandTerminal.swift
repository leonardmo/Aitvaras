import SwiftUI
import AitvarasAgents

struct AgentCommandTerminal<Details: View>: View {
    let command: AgentCommandTranscript
    let entryID: UUID
    let featured: Bool
    let awaitingApproval: Bool
    let hasDetails: Bool
    @ViewBuilder var details: () -> Details

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var showsRunningOutput = false
    @State private var expandedByUser: Bool?
    @State private var showsFullOutput = false

    private var isLight: Bool { colorScheme == .light }
    private var surface: Color {
        isLight ? Color(red: 0.966, green: 0.975, blue: 0.984) : Color(red: 0.071, green: 0.090, blue: 0.121)
    }
    private var headerSurface: Color {
        isLight ? Color(red: 0.925, green: 0.945, blue: 0.963) : Color(red: 0.104, green: 0.130, blue: 0.171)
    }
    private var primaryInk: Color {
        isLight ? Color(red: 0.15, green: 0.21, blue: 0.29) : Color(red: 0.88, green: 0.92, blue: 0.97)
    }
    private var secondaryInk: Color {
        isLight ? Color(red: 0.33, green: 0.39, blue: 0.47) : Color(red: 0.67, green: 0.73, blue: 0.81)
    }
    private let radius: CGFloat = 10

    private var expanded: Bool {
        expandedByUser ?? (featured && (command.status == .failed || (canShowRunningOutput && showsRunningOutput)))
    }

    private var canShowRunningOutput: Bool {
        featured && command.status == .running && !awaitingApproval
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                expandedByUser = !expanded
                if !expanded { showsFullOutput = false }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(secondaryInk)
                        .accessibilityHidden(true)
                    Text("$")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text(verbatim: command.command.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(primaryInk)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                    timing
                    Label(statusLabel, systemImage: statusIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(accent.opacity(0.13), in: Capsule())
                        .fixedSize()
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: statusLabel)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(headerSurface)
            .help(command.command)
            .accessibilityLabel("\(expanded ? "Hide" : "Show") output for \(command.command), \(statusLabel)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("chat.command.toggle.\(entryID)")

            if expanded {
                VStack(alignment: .leading, spacing: 0) {
                    Rectangle().fill(accent.opacity(0.25)).frame(height: 1)
                    output
                    if showsFullOutput {
                        details()
                            .foregroundStyle(secondaryInk)
                            .padding(.horizontal, 11)
                    }
                    if command.status != .running && (!command.output.isEmpty || hasDetails || command.exitCode != nil) {
                        HStack {
                            if let exitCode = command.exitCode {
                                Text("Exit \(exitCode)").font(.system(size: 10, design: .monospaced))
                            }
                            Spacer()
                            if !command.output.isEmpty || hasDetails {
                                Button(outputAction) { showsFullOutput.toggle() }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(primaryInk)
                                    .accessibilityIdentifier("chat.command.fullOutput.\(entryID)")
                            }
                        }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(secondaryInk)
                        .padding(.horizontal, 11)
                        .padding(.bottom, 8)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -5)))
            }
        }
        .background(surface)
        .clipShape(.rect(cornerRadius: radius))
        .overlay {
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(accent.opacity(expanded ? 0.30 : 0.19))
                .allowsHitTesting(false)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: expanded)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: showsFullOutput)
        .task(id: canShowRunningOutput) {
            if canShowRunningOutput {
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                showsRunningOutput = true
            } else {
                showsRunningOutput = false
            }
        }
    }

    private var output: some View {
        AgentTerminalOutput(text: showsFullOutput ? command.output : command.tail,
                            isLive: command.status == .running,
                            showsFullOutput: showsFullOutput,
                            emptyLabel: emptyLabel,
                            ink: primaryInk,
                            mutedInk: secondaryInk)
            .accessibilityIdentifier("chat.tool.\(entryID).output")
    }

    @ViewBuilder private var timing: some View {
        if command.status == .running, !awaitingApproval, let start = command.startedAt {
            TimelineView(.periodic(from: start, by: 1)) { tick in
                time(tick.date.timeIntervalSince(start))
                    .accessibilityHidden(true)
            }
            .accessibilityHidden(true)
        } else if [.succeeded, .failed].contains(command.status), let duration = command.duration {
            time(duration)
        }
    }

    private func time(_ seconds: TimeInterval) -> some View {
        let seconds = max(0, seconds)
        let label = seconds < 1 && command.status != .running ? "<1s"
            : Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow, maximumUnitCount: 2))
        return Text(label)
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(secondaryInk)
            .fixedSize()
    }

    private var statusLabel: String {
        if awaitingApproval && command.status == .running { return "Awaiting approval" }
        return switch command.status {
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .denied: "Denied"
        case .unconfirmed: "No result"
        }
    }

    private var statusIcon: String {
        if awaitingApproval && command.status == .running { return "hand.raised" }
        return switch command.status {
        case .running: "clock"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .denied: "hand.raised.fill"
        case .unconfirmed: "questionmark.circle"
        }
    }

    private var accent: Color {
        if awaitingApproval && command.status == .running { return secondaryInk }
        return switch command.status {
        case .running: isLight ? Color(red: 0.14, green: 0.35, blue: 0.56) : Color(red: 0.57, green: 0.78, blue: 1)
        case .succeeded: isLight ? Color(red: 0.08, green: 0.42, blue: 0.31) : Color(red: 0.49, green: 0.87, blue: 0.71)
        case .failed: isLight ? Color(red: 0.64, green: 0.22, blue: 0.24) : Color(red: 1, green: 0.63, blue: 0.60)
        case .denied, .unconfirmed: secondaryInk
        }
    }

    private var outputAction: String {
        if command.output.isEmpty { return showsFullOutput ? "Hide details" : "Details" }
        return showsFullOutput ? "Show last lines" : "Full output"
    }

    private var emptyLabel: String {
        if command.status != .running { return "No output" }
        return awaitingApproval ? "Waiting for approval" : "Waiting for output…"
    }
}

private struct AgentTerminalOutput: View {
    let text: String
    let isLive: Bool
    let showsFullOutput: Bool
    let emptyLabel: String
    let ink: Color
    let mutedInk: Color

    @State private var pending = ""
    @State private var visible = ""

    var body: some View {
        let output = isLive ? visible : text
        ScrollView(showsFullOutput ? [.horizontal, .vertical] : .horizontal) {
            Text(verbatim: output.isEmpty ? emptyLabel : output)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(output.isEmpty ? mutedInk : ink)
                .lineSpacing(3)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
        }
        .defaultScrollAnchor(.bottomLeading, for: .initialOffset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: showsFullOutput ? 182 : isLive ? 134 : nil, alignment: .topLeading)
        .onChange(of: text, initial: true) { pending = text }
        .task(id: isLive) {
            guard isLive else { return }
            visible = text
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(120)) } catch { break }
                if visible != pending { visible = pending }
            }
        }
    }
}
