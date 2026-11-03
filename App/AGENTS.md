# App target rules

- After adding or removing files, run `xcodegen generate` (`make app` does
  this). `Aitvaras.xcodeproj` is generated and gitignored; edit `project.yml`
  instead.
- `make app` must pass for any change here. `swift test` does not compile
  this target.
- Keep logic in the AitvarasKit package where it can be unit-tested. Views and
  `@MainActor` models in `App/` stay thin.
- Chat is one surface. Assistants and providers (Local / Codex / Claude) are
  switched inside the existing Chat view, not added as separate sections or
  modes.
- Verify visible changes in an isolated profile, never the default one:
  ```sh
  export AITVARAS_STATE_DIR=$(mktemp -d) AITVARAS_SHARE_MODELS=1
  .build-xcode/Build/Products/Debug/Aitvaras.app/Contents/MacOS/Aitvaras --seed-demo-state
  ```
  For screenshots without Screen Recording permission use
  `AITVARAS_UI_TEST_MODE=1 … --uishot /tmp/shot.png` (`docs/TESTING.md`,
  Layer 3).
- Approval and confirmation UI must reflect the autonomy policy: anything
  `confirmable` gets a visible card and is never auto-accepted.
