# Security policy

Aitvaras handles personal data (mail, calendar, memory, homelab access), so
security reports are taken seriously.

## Reporting

Please report vulnerabilities privately via
[GitHub security advisories](https://github.com/leonardmo/Aitvaras/security/advisories/new),
not as a public issue. Include steps to reproduce with synthetic data. You
can expect a reply within a week.

## Scope

In scope:

- ways to make Aitvaras perform a side effect without passing the autonomy
  policy, or without an activity-log entry
- any path to sending email
- prompt injection from mail, web or note content that reaches tools
- secrets ending up outside the Keychain (database, logs, files)
- data leaving the Mac without the disclosed, user-enabled cloud feature

Only the latest `main` is supported.
