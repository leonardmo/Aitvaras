# Contributing

Aitvaras is a personal project. It is developed in the open by its
maintainer and a few coding agents. The full working rules, for humans and
agents alike, are in [AGENTS.md](AGENTS.md). This page is the short version.

## Setup

Requirements: Apple Silicon Mac, macOS 26+, Xcode 27 (full Xcode, not just
the command line tools, with the Metal Toolchain component installed), [XcodeGen](https://github.com/yonaskolb/XcodeGen),
and Node 22+ for the sidecar helper tests.

```sh
git clone https://github.com/leonardmo/Aitvaras.git && cd Aitvaras
git config user.email "<id>+<user>@users.noreply.github.com"   # public repo
make setup     # enable git hooks
make check     # privacy sweep, Node helper tests, swift test
make app       # Debug app build
```

Run the app against a throwaway profile, never your real one; see
[docs/TESTING.md](docs/TESTING.md), Layer 3.

## Changes

- Branch from `main` (`feat/…`, `fix/…`, `docs/…`, `claude/…`, `codex/…`),
  ideally in its own `git worktree`.
- Keep commits focused. `make check` must pass, plus `make app` for UI work.
- Open a PR against `main`. CI (privacy and commit hygiene, package and Node
  tests, app build) must be green; PRs are squash-merged.
- Product and architecture changes start with
  [docs/DECISIONS.md](docs/DECISIONS.md).
- Never commit personal or installation-specific data. The pre-commit hook
  and CI enforce the basics.

## Releases

The maintainer cuts releases:

1. Move the `Unreleased` items in [CHANGELOG.md](CHANGELOG.md) under a new
   version heading and merge that change.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`.

The `Release` workflow builds the app and attaches a zip to a GitHub
Release. It signs and notarizes when the signing secrets are configured;
otherwise the build is ad-hoc signed.

## Repository settings

Branch rules, merge options, security features and labels are kept as code
in `scripts/configure-github.sh`. Re-run it after changing what it sets.

## License

The repository is source-available for portfolio and review purposes. No
license is granted (see README). Contributions are welcome as issues and
discussion; code PRs from outside contributors may not be accepted for that
reason.
