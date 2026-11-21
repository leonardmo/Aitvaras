import SwiftUI
import AppKit
import AitvarasAgents

/// Each row keeps its identity as deltas arrive; details start collapsed.
struct AgentTranscriptView: View {
    let entry: AgentTranscriptEntry
    var streaming = false
    var quote: ((String?) -> Void)? = nil
    var fork: (() -> Void)? = nil
    var forkEnabled = false
    var edit: (() -> Void)? = nil
    var recovery: ((AgentRecoveryAction) -> Void)? = nil
    var recoveryEnabled = false
    var recoveryError: String? = nil
    var autoContinue: AgentAutoContinueRow? = nil
    var autoContinueChange: ((AgentAutoContinueRowOption) -> Void)? = nil
    var autoContinueUpdating = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.kind == "wakeup" {
                Label(entry.text, systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let stop = entry.stoppedTurn {
                let showsAutomaticReset = autoContinue?.enabled == true && autoContinue?.status != nil
                let label = showsAutomaticReset ? "Usage limit reached" : stop.label()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: stop.icon).foregroundStyle(stop.reason.kind == .internalError ? Color.orange : Color.secondary)
                            .accessibilityIdentifier(stop.reason.kind == .interrupted ? "chat.interrupted" : "chat.stopped.icon.\(entry.id)")
                        Text(label).lineLimit(1).truncationMode(.middle).help(label)
                        Spacer(minLength: 6)
                        if let recoveryError {
                            Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                                .help(recoveryError).accessibilityLabel(recoveryError)
                        }
                        ForEach(stop.actions, id: \.rawValue) { action in
                            Button(action.label) {
                                if action == .copyDetails {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(stop.reason.category.name, forType: .string)
                                } else { recovery?(action) }
                            }
                            .disabled(action != .copyDetails && (!recoveryEnabled || (action == .continueTurn && !stop.canContinue)))
                            .help(action == .continueTurn && !stop.canContinue ? "The original session is unavailable." : action.label)
                            .accessibilityIdentifier("chat.stopped.\(action.rawValue).\(entry.id)")
                        }
                    }
                    if let autoContinue {
                        Toggle("Auto-continue when the limit resets", isOn: Binding(
                            get: { autoContinue.enabled }, set: { autoContinueChange?(.enabled($0)) }))
                            .toggleStyle(.checkbox)
                            .disabled(!autoContinue.canToggle || autoContinueUpdating)
                            .accessibilityIdentifier("chat.stopped.autoContinue.\(entry.id)")
                        Toggle("Keep Mac awake until it continues", isOn: Binding(
                            get: { autoContinue.keepAwake }, set: { autoContinueChange?(.keepAwake($0)) }))
                            .toggleStyle(.checkbox)
                            .disabled(!autoContinue.canChangeKeepAwake || autoContinueUpdating)
                            .help("Keeps the Mac awake while waiting on AC power.")
                            .accessibilityIdentifier("chat.stopped.keepAwake.\(entry.id)")
                        if let status = autoContinue.status {
                            Text(status).foregroundStyle(.secondary)
                                .accessibilityIdentifier("chat.stopped.autoContinueStatus.\(entry.id)")
                        }
                    }
                }.font(.caption).controlSize(.small)
            } else if entry.kind == "automaticContinuation" {
                Label("Continued automatically after the usage reset", systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.continued.automatic.\(entry.id)")
            } else if entry.kind == "continued" {
                Label("Continued", systemImage: "arrow.turn.down.right")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.continued.\(entry.id)")
            } else if entry.kind == "hook" {
                hookRow(payload ?? .null)
            } else if entry.kind == "importedHistory" {
                importedHistory
            } else if ["handover", "thinking", "tool"].contains(entry.kind) {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if entry.kind == "tool" {
                                toolDetails
                                ForEach(entry.toolHooks) { hook in
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            foldedHookIcon(hook)
                                            Text(hook.name).lineLimit(2)
                                            Text(hook.eventLabel).foregroundStyle(.secondary)
                                        }
                                        if let reason = hook.reason, !reason.isEmpty {
                                            Text(reason).foregroundStyle(.secondary).textSelection(.enabled)
                                        }
                                    }.font(.caption)
                                }
                            } else {
                                Text(AgentTranscriptContent.bounded(entry.text))
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                    }
                    .frame(maxHeight: 240)
                } label: {
                    HStack(spacing: 6) {
                        if entry.kind == "tool" {
                            Image(systemName: entry.toolPresentationIcon)
                        }
                        Text(title).lineLimit(1).truncationMode(.middle)
                        if entry.kind == "tool" {
                            ForEach(entry.toolHooks) { hook in foldedHookIcon(hook) }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
                if entry.kind == "tool" {
                    if let reason = entry.blockedHookReason {
                        Text(reason).font(.caption).foregroundStyle(.red).lineLimit(1).truncationMode(.tail)
                            .help(reason).padding(.leading, 12)
                            .accessibilityIdentifier("chat.tool.\(entry.id).blockedReason")
                    }
                }
            } else if entry.kind == "user" {
                HStack {
                    Spacer(minLength: 30)
                    VStack(alignment: .trailing, spacing: 4) {
                        ChatMarkdown(text: entry.displayText, quote: quote, edit: edit)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let attachments = payload?["composer"]?["attachments"]?.arrayValue {
                            ForEach(Array(attachments.enumerated()), id: \.offset) { _, file in
                                Label(file["name"]?.stringValue ?? "File", systemImage: file["kind"]?.stringValue == "image" ? "photo" : "doc")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        if let status = followupLabel {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("chat.followup.\(entry.id)")
                        }
                    }
                    .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
                if let output = entry.claudeCommandOutput, !output.isEmpty {
                    ScrollView(.horizontal) {
                        Text(verbatim: output)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .padding(10)
                    }
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.leading, 30)
                    .padding(.top, 4)
                    .accessibilityIdentifier("chat.commandResult.\(entry.id)")
                }
            } else {
                if entry.kind == "assistant", let quote {
                    ChatMarkdown(text: entry.text, quote: quote, fork: fork, forkEnabled: forkEnabled, streaming: streaming)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(entry.text)
                } else {
                    ChatMarkdown(text: entry.text, streaming: streaming).frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(entry.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(entry.presentationIdentifier)
        // Give completion a fresh AX container as well as a new identifier,
        // keeping the row identity stable throughout streaming.
        .id(entry.presentationIdentifier)
    }
    private func foldedHookIcon(_ hook: AgentToolHookPresentation) -> some View {
        Image(systemName: hook.icon)
            .foregroundStyle(hook.status == .blocked ? Color.red : hook.status == .failed ? Color.orange : Color.secondary)
            .help(hook.accessibilityLabel)
            .accessibilityLabel(hook.accessibilityLabel)
            .accessibilityIdentifier("chat.tool.\(entry.id).hook.\(hook.id)")
    }
    @ViewBuilder private func hookRow(_ hook: JSONValue) -> some View {
        let phase = hook["phase"]?.stringValue ?? "interrupted"
        let label = hook["statusMessage"]?.stringValue ?? hook["name"]?.stringValue ?? "Hook"
        let reason = hook["reason"]?.stringValue ?? ""
        if phase == "success" {
            DisclosureGroup {
                Text(hook["name"]?.stringValue ?? "Hook").font(.caption).textSelection(.enabled)
            } label: { Label(label, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary) }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if phase == "running" { ProgressView().controlSize(.mini) }
                    else { Image(systemName: phase == "blocked" ? "hand.raised" : "exclamationmark.circle") }
                    Text(label)
                }.font(.caption)
                if !reason.isEmpty { Text(reason).font(.caption.monospaced()).textSelection(.enabled) }
            }.foregroundStyle(phase == "blocked" || phase == "error" ? Color.orange : Color.secondary)
        }
    }
    private var importedHistory: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Read-only · not sent to providers")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(entry.importedMessages) { message in
                        if message.kind == "user" {
                            ChatMarkdown(text: message.text)
                                .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                                .accessibilityIdentifier("chat.entry.\(message.id)")
                        } else {
                            ChatMarkdown(text: message.text).frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("chat.entry.\(message.id)")
                        }
                    }
                }.padding(.vertical, 6)
            }.frame(maxHeight: 360)
        } label: {
            Label(entry.text, systemImage: "clock.arrow.circlepath")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var followupLabel: String? {
        switch payload?["followup"]?.stringValue {
        case "queued": "Queued"
        case "steering": "Sending"
        case "steered": "Steered"
        case "interrupted": "Interrupted"
        case "notSent": "Not sent"
        default: nil
        }
    }
    private var payload: JSONValue? { entry.payloadJSON.flatMap(JSONValue.parse) }
    private var title: String {
        if entry.kind == "handover" { return "Context sent to \(entry.provider.rawValue.capitalized)" }
        if entry.kind == "thinking" { return "Thinking" }
        if entry.kind == "tool", entry.text.isEmpty, let hook = payload?["hooks"]?.arrayValue?.first {
            return hook["name"]?.stringValue ?? "Hook"
        }
        let input = payload?["input"] ?? .null
        return AgentActionPresentation.toolSummary(.init(name: entry.text, input: input),
            finished: payload?["finished"]?.boolValue == true,
            isError: payload?["isError"]?.boolValue == true,
            completionUnconfirmed: payload?["completionUnconfirmed"]?.boolValue == true,
            turnCompletedNormally: payload?["turnCompletedNormally"]?.boolValue == true,
            isDenied: payload?["isDenied"]?.boolValue == true)
    }
    @ViewBuilder private var toolDetails: some View {
        let input = payload?["input"] ?? .null
        let partial = payload?["partialInput"]?.stringValue ?? ""
        let output = AgentTranscriptContent.display(payload?["output"] ?? .null)
        let inputText = partial.isEmpty || input != .object([:]) && input != .null
            ? AgentTranscriptContent.display(input) : partial
        if !inputText.isEmpty {
            Text("Input").font(.caption.weight(.medium))
            Text(inputText).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("chat.tool.\(entry.id).input")
        }
        if !output.isEmpty {
            Text(payload?["isError"]?.boolValue == true ? "Error" : "Output").font(.caption.weight(.medium))
            Text(output).font(.caption.monospaced()).textSelection(.enabled)
                .accessibilityIdentifier("chat.tool.\(entry.id).output")
        }
    }
}
