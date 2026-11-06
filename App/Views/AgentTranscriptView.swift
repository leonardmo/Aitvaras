import SwiftUI
import AitvarasAgents

/// Each row keeps its identity as deltas arrive; details start collapsed.
struct AgentTranscriptView: View {
    let entry: AgentTranscriptEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.kind == "importedHistory" {
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
            } else if entry.kind == "user" {
                HStack {
                    Spacer(minLength: 30)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(entry.text).textSelection(.enabled)
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
            } else {
                ChatMarkdown(text: entry.text).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(entry.text)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(entry.presentationIdentifier)
        // Give completion a fresh AX container as well as a new identifier,
        // keeping the row identity stable throughout streaming.
        .id(entry.presentationIdentifier)
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
