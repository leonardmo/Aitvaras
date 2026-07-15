# Aitvaras: agent notes

Local-first agentic AI assistant for macOS with a 3D companion character and DE/EN voice. The product, repository, project, targets, modules, bundle identifier, state paths, and assistant identity are all named **Aitvaras** (Lithuanian household dragon; see `docs/AITVARAS.md`). Read `docs/DECISIONS.md` before changing direction on anything; it is the source of truth for product/architecture decisions (numbered; update it when a decision changes). `docs/ROADMAP.md` tracks milestone status; `docs/MASTERPLAN.md` holds the forward plan.

Machine-specific context (the developer's paths, accounts, hardware) lives in `CLAUDE.local.md` (gitignored); create your own if it's missing.

## Build

- Core logic: `swift build` / `swift test` at repo root (AitvarasKit package, works without Xcode).
- App target: `xcodegen generate`, then `xcodebuild -project Aitvaras.xcodeproj -scheme Aitvaras -configuration Debug -derivedDataPath .build-xcode -skipMacroValidation -skipPackagePluginValidation build` (both skip flags are required; validation hangs/fails otherwise). Needs full Xcode 26+, macOS 26 SDK.
- Testing strategy incl. isolated app profiles (`AITVARAS_STATE_DIR`, `--seed-demo-state`): `docs/TESTING.md`.

## Hard rules

- Everything runs locally: no cloud LLM APIs, ever. Subprocess sidecars (Python TTS, CLI agents) are fine.
- Aitvaras may only modify Calendar/Reminders items she created herself.
- Aitvaras must NEVER be able to send email (D20): mail tools are read/search only.
- Every side effect goes through AgentCore's autonomy policy (risk levels `read`/`reversibleWrite`/`confirmable`) and is written to the activity log with provenance. Connectors never bypass this.
- Memory writes follow the same discipline: pipeline-extracted sensitive facts are quarantined (`needsReview`) until approved; superseded facts are invalidated, never deleted; hard deletion is a user action.
- Secrets (Moodle cookies, homelab tokens, Telegram bot token) live in the macOS Keychain, never in the DB or files.
- Character aesthetic: rigged 3D human avatar, recognizably human, serious, cyber only as accents. Not anime, not a mascot, not abstract/hologram.
- Swift 6 strict concurrency; engines and connectors are actors.
- GRDB stores UUID columns in its own encoding: never compare/insert UUIDs in raw SQL via `.uuidString` (silent no-ops / FK failures); use record APIs. Exception: FTS mirror tables (`ragFTS`, `factFTS`) key on `.uuidString` text by design.

## Target hardware

Apple Silicon, 32+ GB RAM recommended. Model budget is ~20 GB total (Qwen3-30B-A3B 4-bit ≈ 17 GB + Qwen3-4B ≈ 2.5 GB); never plan for dense 70B-class models.
