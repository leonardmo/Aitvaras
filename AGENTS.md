# Repository operating rules

## Private development delivery

- After a completed, meaningful change, create a focused, descriptive commit and
  push it to the private development repository when useful. This is standing
  user authorization; a separate request to commit or push is not required.
- Run checks appropriate to the change and review the exact staged diff first.
  Stage only the intended work; do not sweep unrelated pending changes into a
  commit. Do not create empty or unnecessary commits merely to satisfy this rule.
- Verify that the push destination is the private development remote. Use normal
  pushes, never force-push without explicit authorization. Report failures or
  remaining uncommitted work rather than claiming everything is synchronized.

## Public repository boundary

- Treat `origin` (`Aitvaras-development`) as the private development remote and
  `public` (`Aitvaras`) as a publish-only remote.
- Never push, force-push, open a pull request, create a release, change settings,
  or otherwise mutate the public repository unless the user explicitly requests
  that specific public action in the current task.
- A request to commit, merge, push, publish, or update the project without
  explicitly naming the public repository does not authorize a public change.
- Before an explicitly requested public update, review the exact outgoing diff
  and run the repository privacy checks.

## Installation-specific data boundary

- Never commit real user or installation-specific values: credentials, tokens,
  cookies, email addresses, usernames, local/remote hostnames, IP addresses,
  Home Assistant entity/device/area names, personal filesystem paths, or
  identifiers copied from a live service.
- Secrets belong only in the profile-scoped macOS Keychain. Non-secret
  connection details belong only in local SQLite/preferences/runtime config.
- Documentation, fixtures and tests must use clearly synthetic examples and
  reserved domains/addresses. If live verification is required, inject its
  values at runtime and ensure commands and logs do not print credentials.
