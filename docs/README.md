# Documentation

## Core references

| Doc | What it is |
|---|---|
| [DECISIONS.md](DECISIONS.md) | Numbered product and architecture decisions; the source of truth. |
| [ARCHITECTURE.md](ARCHITECTURE.md) | Modules and how they fit together. |
| [ROADMAP.md](ROADMAP.md) | Milestones and their status. |
| [MASTERPLAN.md](MASTERPLAN.md) | The forward plan. |
| [TESTING.md](TESTING.md) | Test layers, isolated profiles, manual checklist. |
| [MESSAGE-TRUST.md](MESSAGE-TRUST.md) | External message trust and the phishing boundary. |

## Feature designs

| Doc | Area |
|---|---|
| [CAPTURE-REFINEMENT.md](CAPTURE-REFINEMENT.md) | Lecture capture, source retention, re-transcription. |
| [CLAUDE-INTEGRATION.md](CLAUDE-INTEGRATION.md) | Claude Code provider and account modes. |
| [CODEX-BIDIRECTIONAL-INTEGRATION.md](CODEX-BIDIRECTIONAL-INTEGRATION.md) | Native Codex projects and chats. |
| [CODEX-NATIVE-SETUP.md](CODEX-NATIVE-SETUP.md) | Shared native Codex setup. |
| [FRONTIER-INTEGRATION-STATUS.md](FRONTIER-INTEGRATION-STATUS.md) | Claude/Codex integration checklist. |
| [FRONTIER-CODEX-PROOF.md](FRONTIER-CODEX-PROOF.md) | Codex text-only proof. |
| [NEXT-WORKSPACE-PLAN.md](NEXT-WORKSPACE-PLAN.md) | Structured workspace checkpoints. |
| [WORK-HUB-PLAN.md](WORK-HUB-PLAN.md) | Work hub, durable context, distributed execution. |
| [STEP-ONE-OBSERVABILITY.md](STEP-ONE-OBSERVABILITY.md) | Observability and quiet operation. |
| [UI-MENU-AUDIT.md](UI-MENU-AUDIT.md) | Menu and presentation audit. |
| [MOBILE-COMPANION.md](MOBILE-COMPANION.md) | Mobile companion, multi-device. |
| [FUTURE.md](FUTURE.md) | Ideas beyond the roadmap. |

## Background

- [AITVARAS.md](AITVARAS.md): naming research (German).
- [AITVARAS_CLOUD_AGENT.md](AITVARAS_CLOUD_AGENT.md): instructions Aitvaras
  gives the cloud agents it delegates to.
- [research/](research/): dated research notes.
- [character/](character/): companion character direction.
- [character/dragon-runtime/](character/dragon-runtime/): how the default dragon
  asset is built and checked.
- [archive/](archive/): superseded notes and session logs, kept for history.

## Conventions

- New design docs get a row here. When a doc is superseded, move it to
  `archive/` and fix its inbound links.
- Progress diaries and session logs go in PRs and issues, not in `docs/`.
