import SwiftUI
import AppKit
import AitvarasAgents

/// Each row keeps its identity as deltas arrive; details start collapsed.
struct AgentTranscriptView: View {
    let entry: AgentTranscriptEntry
    var quote: ((String?) -> Void)? = nil
    var fork: (() -> Void)? = nil
    var forkEnabled = false
    var edit: (() -> Void)? = nil
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.kind == "hook" {
                hookRow(payload ?? .null)
            } else if entry.kind == "importedHistory" {
                importedHistory
            } else if ["handover", "thinking", "tool"].contains(entry.kind) {
                DisclosureGroup(isExpanded: $expanded) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if entry.kind == "tool" {
                                toolDetails
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

                    }.font(.caption).foregroundStyle(.secondary)
                }
                if entry.kind == "tool" {
                    ForEach(Array((payload?["hooks"]?.arrayValue ?? []).enumerated()), id: \.offset) { _, hook in
                        hookRow(hook)
                    }.padding(.leading, 12)
                }
            } else if entry.kind == "user" {
                HStack {
                    Spacer(minLength: 30)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(entry.displayText).textSelection(.enabled)
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
                .contextMenu {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(entry.displayText, forType: .string) }
                    if let edit { Button("Edit & resend", action: edit) }
                }
            } else {
                if entry.kind == "assistant", let quote {
                    SelectableMessageText(text: entry.text, quote: quote, fork: fork, forkEnabled: forkEnabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(entry.text)
                } else {
                    ChatMarkdown(text: entry.text).frame(maxWidth: .infinity, alignment: .leading)
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
                            Text(message.text).textSelection(.enabled)
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
