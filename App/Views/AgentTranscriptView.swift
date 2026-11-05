import SwiftUI
import AitvarasAgents

/// Each row keeps its identity as deltas arrive; details start collapsed.
struct AgentTranscriptView: View {
    let entry: AgentTranscriptEntry
    @State private var expanded = false

    var body: some View {
        Group {
            if ["handover", "thinking", "tool"].contains(entry.kind) {
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
                            Image(systemName: payload?["isError"]?.boolValue == true ? "exclamationmark.circle" : "terminal")
                        }
                        Text(title).lineLimit(1).truncationMode(.middle)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            } else if entry.kind == "user" {
                HStack {
                    Spacer(minLength: 30)
                    Text(entry.text).textSelection(.enabled)
                        .padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                }
            } else {
                ChatMarkdown(text: entry.text).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityIdentifier(entry.kind == "handover" ? "chat.handover.\(entry.id)" : "chat.entry.\(entry.id)")
    }
    private var payload: JSONValue? { entry.payloadJSON.flatMap(JSONValue.parse) }
    private var title: String {
        if entry.kind == "handover" { return "Context sent to \(entry.provider.rawValue.capitalized)" }
        if entry.kind == "thinking" { return "Thinking" }
        let input = payload?["input"] ?? .null
        let action = AgentActionPresentation(tool: .init(name: entry.text, input: input))
        let detail = action.detail.components(separatedBy: .newlines).first ?? ""
        return detail.isEmpty ? (entry.text.isEmpty ? "Tool" : entry.text) : "\(entry.text) · \(detail)"
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
