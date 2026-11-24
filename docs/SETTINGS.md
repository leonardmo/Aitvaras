# Aitvaras Settings

Open Settings with Command–comma. The sidebar shows profile pages and projects. Project settings open here from the Chat header or project sidebar. The display, project and agent shortcuts link to their full settings destination when they touch persistent settings.

The chat composer shows five-hour and weekly quota percentages when the selected account reports those windows. Hover over either percentage for the reset time, when available. Use the Preview Markdown button to render a draft in place and the pencil to return to editing. Paste an image into the message field to attach it in Claude or Codex chats.

## Menu inventory

| Former control | Home |
| --- | --- |
| Settings tabs and Setup section picker | Settings sidebar |
| Edit project, Manage projects and the project settings sheet | Settings → Projects → selected project |
| Project name, instructions, default and visibility | Project → General |
| Folder registration, provider file-read switches and boundary review | Project → Folders |
| Codex registration and re-review | Project → Codex link |
| Hooks, permissions source and provider setup | Project → Agent setup |
| Project-native MCP definitions, managed accounts, routing, trust and approval rules | Project → MCP servers |
| Shared MCP definitions and credentials | Settings → Connections |
| Aitvaras gateway scopes and Knowledge sources | Project → Aitvaras tools |
| Providers, accounts and default model/effort | Settings → Providers |
| Cloud feature routing and sharing | Settings → Cloud agents & privacy |
| Voice, companion, capture, memory, permissions and usage pickers | Individual Settings pages |
| Worktree and initial project selection | New Chat setup |
| Current provider, profile, model and effort | Chat → Agent popover |
| Current Chat permissions | Chat → Permissions |
| Attachment, send, stop and gauges | Composer |

`SettingsRegistry` is the source of truth for setting IDs, value types, safety classes and homes. Use the list endpoint below to get the current registry. Collections represent variable-length lists, such as provider profiles, project folders and accounts. Their home opens the corresponding editor.

## Agent guide

Use these tools when the person asks for help with Aitvaras itself. Tool schemas are available to the model. In local chat and voice, the names use `settings.read`, `settings.propose`, `settings.open` and `settings.connections_propose`. Gateway clients see the same definitions as `settings_read`, `settings_propose`, `settings_open` and `settings_connections_propose` (your client can add a gateway namespace).

1. Call **read** without arguments to discover IDs and types. Call it with an `id` for the current value if available to the session. Project IDs come from the verified launch or owning chat. Do not pass your own project IDs or seek credentials in configuration files.
2. Call **propose** with a short `reason` and a `changes` object keyed by setting ID. Use the values and constraints reported by read. For example, `{"reason":"Use the preferred appearance","changes":{"appearance.mode":"system"}}`. A returned review ID means the request is pending. Tell the user it's ready for review.
3. Call **open** with an `id` to highlight its Settings home when the user needs a dedicated editor or system action.
4. For an MCP connection, use **connections_propose** with a catalog key (`linear` or `notion`) or a `draft`. A draft chooses `https` or `stdio`, an auth type (`oauth`, `header`, or `none`), and a URL or command and arguments. Mark user-supplied credential fields in `secretHeaders` or `secretEnvironment`. Never ask for or pass a credential in chat, arguments, environment literals or URLs. Aitvaras requests those values securely during review. Use project scope by default and show the exact command or endpoint.
5. For a managed server, a tool classified Read can run under Auto-allow reads. Ask requires approval for that tool. Full auto is a user decision. Protected operations are denied or require a separate confirmation. An Always allow grant is pinned to the project, account and tool revision. For native stdio and provider-managed HTTP/SSE, the provider loads the definition and enforces its tool permissions.

Use official service documentation to draft custom configuration. See the sources for [Linear MCP](https://linear.app/docs/mcp) and [Notion MCP](https://developers.notion.com/guides/mcp/get-started-with-mcp).

For `project.folders`, send an array of absolute paths to add. Existing folders
are retained and provider file access returns to review. For
`project.gatewayTools`, send the complete list of scope names to review. For
`routines.status`, send a one-entry object mapping an already approved routine
ID to `active` or `paused`. Use the user-facing editor for a new routine or a
schedule change.
