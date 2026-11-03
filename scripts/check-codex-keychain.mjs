// macOS-only, no OAuth/network/model. The probe adds/deletes its own unique
// nonsensitive Keychain item; no existing item or global setting is changed.
import fs from 'node:fs';
import path from 'node:path';
import { userInfo } from 'node:os';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { prepareProfile, launchPolicy } from '../Sources/AitvarasConnectors/Resources/codex-interactive.mjs';

assert.equal(process.platform, 'darwin');
const root = fs.mkdtempSync('/private/tmp/aitvaras-keychain-check-');
fs.chmodSync(root, 0o700);
const home = fs.realpathSync(userInfo().homedir);
const canaryParent = fs.mkdtempSync(path.join(home, '.aitvaras-synthetic-boundary-'));
const profileParent = path.join(canaryParent, 'profile'); fs.mkdirSync(profileParent, { mode: 0o700 });
const profile = prepareProfile(profileParent);
const canary = path.join(canaryParent, 'AGENTS.md'); fs.writeFileSync(canary, 'SYNTHETIC_PRIVATE_HOME_CANARY');
try {
  const binary = path.join(root, 'probe');
  const source = fileURLToPath(new URL('./fixtures/codex-keychain-probe.swift', import.meta.url));
  const built = spawnSync('/usr/bin/xcrun', ['swiftc', source, '-o', binary], { encoding: 'utf8', timeout: 30000 });
  assert.equal(built.status, 0, 'Synthetic probe compilation failed.');
  const env = { HOME: home, CODEX_HOME: profile.codex, PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' };
  const policy = launchPolicy(profile, home) + '(deny network*)';
  const blocked = spawnSync('/usr/bin/sandbox-exec', ['-p', policy, '/bin/cat', canary], { env, timeout: 5000 });
  assert.notEqual(blocked.status, 0); assert.equal(blocked.stdout.length, 0);
  const allowed = spawnSync('/usr/bin/sandbox-exec', ['-p', policy, '/bin/cat', path.join(profile.root, 'owner')], { env, timeout: 5000 });
  assert.equal(allowed.status, 0);
  const canonical = spawnSync('/usr/bin/sandbox-exec', ['-p', policy, process.execPath, '-e',
    "require('node:fs').realpathSync(process.argv[1])", profile.root], { env, timeout: 5000 });
  assert.equal(canonical.status, 0, 'Owned profile ancestry must be resolvable without home-content access.');
  const listing = spawnSync('/usr/bin/sandbox-exec', ['-p', policy, '/bin/ls', canaryParent], { env, timeout: 5000 });
  assert.notEqual(listing.status, 0); assert.equal(listing.stdout.length, 0);
  const result = spawnSync('/usr/bin/sandbox-exec', ['-p', policy, binary], { env, encoding: 'utf8', timeout: 15000 });
  const statuses = JSON.parse(result.stdout.trim());
  assert.deepEqual(statuses, { lookup: 0, added: 0, deleted: 0 });
  assert.equal(result.status, 0);
  console.log(JSON.stringify({ keychainLookupWriteDelete: true, privateHomeReadBlocked: true, ownedProfileReadAllowed: true, networkAllowed: false }));
} finally {
  fs.rmSync(canaryParent, { recursive: true, force: true });
  fs.rmSync(root, { recursive: true, force: true });
}
