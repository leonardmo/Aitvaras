// Synthetic contract tests. No credentials, network provider, or model inference.
// Optional --native-preflight <absolute codex> runs only a clean unauthenticated
// startup and thread creation under an outer deny-all-network Seatbelt, never
// login or a turn. The same profile must pass again after native writes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { userInfo } from 'node:os';
import { Runtime, prepareProfile, preflight, validateConfig, SETTINGS, launchArguments, launchPolicy, validID } from '../Sources/AitvarasConnectors/Resources/codex-interactive.mjs';

const root = fs.mkdtempSync('/private/tmp/aitvaras-contract-'); fs.chmodSync(root, 0o700);
const helper = fileURLToPath(new URL('../Sources/AitvarasConnectors/Resources/codex-interactive.mjs', import.meta.url));
let index = 0;
const homeFixtures = [];
function fresh() { const p = path.join(root, `case-${++index}`); fs.mkdirSync(p, { mode: 0o700 }); return p; }
function layers(profile) { return { layers: [
  { name: { type: 'sessionFlags' }, config: structuredClone(SETTINGS) },
  { name: { type: 'user', file: path.join(profile.codex, 'config.toml') }, config: {} },
  { name: { type: 'system', file: '/etc/codex/config.toml' }, config: {} }
] }; }
let passed = 0;
async function test(name, fn) { await fn(); passed++; console.log(JSON.stringify({ test: name, passed: true })); }

class SyntheticRuntime extends Runtime {
  calls = [];
  async attest() {}
  startServer() { this.child = { stdin: { write() {} } }; }
  async stop() {}
  async rpc(method, params) {
    this.calls.push({ method, params });
    if (this.onRPC) await this.onRPC(method, params);
    switch (method) {
    case 'initialize': return {};
    case 'config/read': return layers(this.profile);
    case 'configRequirements/read': return { requirements: null };
    case 'account/read': return { account: { type: 'chatgpt' } };
    case 'account/login/start':
      this.notification('account/login/completed', { loginId: 'synthetic-login', success: !this.loginFails,
        error: this.loginFails ? 'Synthetic keychain persistence failure' : null });
      return { type: 'chatgpt', loginId: 'synthetic-login', authUrl: 'https://auth.openai.com/synthetic-fixture' };
    case 'model/list': return { data: [{ id: 'synthetic-catalog-row', model: 'synthetic-model', displayName: 'Synthetic model', supportedReasoningEfforts: [{ reasoningEffort: 'low' }] }], nextCursor: null };
    case 'account/rateLimits/read':
      if (this.noQuota) throw Object.assign(new Error('Synthetic quota unavailable'), { code: 'rejected' });
      return { rateLimits: { primary: { usedPercent: 25, windowDurationMins: 300, resetsAt: 2000000000 }, secondary: null } };
    case 'thread/start': return { thread: { id: 'owned-synthetic-id' } };
    case 'thread/resume': return { thread: { id: params.threadId } };
    case 'turn/start': {
      const turn = { id: 'synthetic-turn', status: 'inProgress' };
      this.notification('turn/started', { threadId: this.threadID, turn });
      if (!this.hold) {
        this.notification('item/agentMessage/delta', { threadId: this.threadID, turnId: turn.id, delta: 'Synthetic reply.' });
        this.notification('thread/tokenUsage/updated', { threadId: this.threadID, turnId: turn.id, tokenUsage: { last: { inputTokens: 4, outputTokens: 3 } } });
        this.notification('turn/completed', { threadId: this.threadID, turn: { ...turn, status: this.endState ?? 'completed' } });
      }
      return { turn };
    }
    case 'turn/interrupt': return {};
    default: throw new Error('Unexpected synthetic method.');
    }
  }
}
function synthetic(overrides = {}, ack = () => Promise.resolve()) {
  const events = [];
  const runtime = new SyntheticRuntime({ operation: 'run', executable: '/synthetic/codex', profileDirectory: fresh(),
    context: 'Approved synthetic context', model: 'synthetic-model', effort: 'low', prompt: 'Synthetic prompt', ...overrides },
  event => events.push(event), ack);
  return { runtime, events };
}

try {
  if (process.argv[2] === '--native-worker') {
    class InspectRuntime extends Runtime {
      launch(args) {
        assert(!this.stopped);
        this.stopping = undefined;
        const policy = launchPolicy(this.profile, this.systemHome) + '(deny network*)';
        const child = spawn('/usr/bin/sandbox-exec', ['-p', policy, this.request.executable, ...args],
          { env: this.env, cwd: this.cwd, detached: true, stdio: ['pipe', 'pipe', 'ignore'] });
        this.child = child; this.group = child.pid;
        child.stdin.on('error', () => this.abort()); child.once('error', () => this.abort());
        return child;
      }
      async rpc(method, params) {
        assert(['initialize', 'config/read', 'configRequirements/read', 'account/read'].includes(method),
          'Native fixture must never send login, turn, model or quota requests.');
        const result = await super.rpc(method, params);
        if (method === 'account/read') {
          assert.equal(result.account, null, 'Native fixture must remain unauthenticated.');
          // Create a native thread without ever starting a turn. This exercises
          // writer-lock/runtime artifacts while the outer sandbox denies network.
          const thread = await super.rpc('thread/start', {
            cwd: this.cwd, modelProvider: 'openai', permissions: 'aitvaras_text_only',
            approvalPolicy: 'never', approvalsReviewer: 'user', runtimeWorkspaceRoots: [],
            baseInstructions: 'Synthetic no-model preflight.', developerInstructions: '',
            ephemeral: false, environments: [], selectedCapabilityRoots: [], dynamicTools: [],
            allowProviderModelFallback: false
          });
          assert(validID(thread.thread?.id));
          console.log(JSON.stringify({ nativeRuntimeArtifacts: ['.sandbox_migration', 'thread-writer-locks',
            'thread-writer-locks/.coordination.lock', `thread-writer-locks/${thread.thread.id}.lock`].map(relative => {
            const s = fs.lstatSync(path.join(this.profile.codex, relative));
            return { relative: relative.replace(thread.thread.id, '<thread-id>'), type: s.isDirectory() ? 'directory' : 'file', mode: (s.mode & 0o777).toString(8), size: s.size };
          }) }));
          preflight(this.profile);
        }
        return result;
      }
      async gate() {
        try { return await super.gate(); }
        catch (e) {
          console.log(JSON.stringify({ nativeArtifactTypes: ['home', 'codex'].flatMap(name => fs.readdirSync(this.profile[name], { recursive: true }).map(relative => {
            const s = fs.lstatSync(path.join(this.profile[name], relative));
            return { relative: `${name}/${relative}`, type: s.isSymbolicLink() ? 'symlink' : s.isDirectory() ? 'directory' : 'file' };
          })) }));
          throw e;
        }
      }
    }
    const runtime = new InspectRuntime({ operation: 'status', executable: process.argv[3], profileDirectory: process.argv[4] },
      () => {}, () => Promise.reject(new Error('No thread permitted.')));
    process.on('SIGTERM', () => runtime.abort());
    try { console.log(JSON.stringify({ event: 'result', result: await runtime.execute() })); }
    catch (e) { console.log(JSON.stringify({ event: 'error', code: e.code ?? 'unavailable' })); process.exitCode = 1; }
  } else if (process.argv[2] === '--native-preflight') {
    assert.equal(process.platform, 'darwin'); assert(path.isAbsolute(process.argv[3] ?? ''));
    let profile = fresh();
    if (process.argv.includes('--profile-in-home')) {
      const base = fs.mkdtempSync(path.join(fs.realpathSync(userInfo().homedir), '.aitvaras-native-preflight-'));
      fs.chmodSync(base, 0o700); homeFixtures.push(base);
      profile = path.join(base, 'Application Support', 'Synthetic profile');
      fs.mkdirSync(profile, { recursive: true, mode: 0o700 });
    }
    for (let round = 1; round <= 2; round++) {
      const child = spawn(process.execPath, [fileURLToPath(import.meta.url), '--native-worker', process.argv[3], profile],
        { env: { PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' }, stdio: ['pipe', 'pipe', 'ignore'] });
      const timer = setTimeout(() => child.kill('SIGTERM'), 50000);
      child.stdin.write(JSON.stringify({ operation: 'status', executable: process.argv[3], profileDirectory: profile }) + '\n');
      let data = '';
      child.stdout.on('data', c => { data += c; assert(data.length < 1024 * 1024); });
      await new Promise(resolve => child.once('close', resolve)); clearTimeout(timer);
      const frames = data.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
      const result = frames.find(f => f.event === 'result');
      const error = frames.find(f => f.event === 'error');
      for (const diagnostic of frames.filter(f => f.nativeArtifactTypes || f.nativeRuntimeArtifacts)) console.log(JSON.stringify(diagnostic));
      console.log(JSON.stringify({ nativePreflight: result?.result?.authenticated === false, round, error: error?.code ?? null,
        artifacts: fs.readdirSync(path.join(profile, 'codex-interactive', 'codex'), { recursive: true }) }));
      assert(result?.result?.authenticated === false, 'Native isolated startup failed closed.');
      preflight(prepareProfile(profile));
    }
    const contaminated = prepareProfile(profile);
    fs.writeFileSync(path.join(contaminated.codex, 'config.toml'), 'developer_instructions = "synthetic contamination"\n', { mode: 0o600 });
    assert.throws(() => prepareProfile(profile), { code: 'unsafeProfile' });
    console.log(JSON.stringify({ nativeRepeatedPreflight: true, contaminatedConfigBlocked: true, turnsStarted: 0, realAuthentication: false }));
  } else {
    await test('valid owned identifiers only', () => { assert(validID('owned-id')); for (const v of ['../native', 'id\n', '', 'a/b', 'a'.repeat(129)]) assert(!validID(v)); });
    await test('raw config exact layers and requirements', () => {
      const p = prepareProfile(fresh()); validateConfig(layers(p), { requirements: null }, p);
      for (const mutate of [x => { x.layers[0].config.mcp_servers = {}; }, x => { x.layers[1].config.hooks = {}; },
        x => { x.layers[2].config.features = { shell_tool: true }; }, x => { x.layers.push({ name: { type: 'project' }, config: {} }); },
        x => { x.layers[1].name.file = '/synthetic/native/config.toml'; }, x => { x.layers[1].name.profile = 'unsafe'; }]) {
        const data = layers(p); mutate(data); assert.throws(() => validateConfig(data, { requirements: null }, p));
      }
      assert.throws(() => validateConfig(layers(p), { requirements: {} }, p));
      assert.throws(() => validateConfig(layers(p), {}, p));
    });
    await test('preflight refuses config instructions auth and symlinks', () => {
      for (const name of ['config.toml', 'AGENTS.md', 'auth.json', 'skills', 'plugins', 'hooks', 'mcp.json']) {
        const p = prepareProfile(fresh()); fs.writeFileSync(path.join(p.codex, name), 'synthetic', { mode: 0o600 });
        assert.throws(() => preflight(p));
      }
      const p = prepareProfile(fresh()); fs.symlinkSync('/synthetic', path.join(p.codex, 'models_cache.json')); assert.throws(() => preflight(p));
    });
    await test('pinned migration and writer-lock artifacts survive repeated preflight', () => {
      const p = prepareProfile(fresh());
      fs.writeFileSync(path.join(p.codex, '.sandbox_migration'), 'v1\n', { mode: 0o600 });
      fs.mkdirSync(path.join(p.codex, 'thread-writer-locks'), { mode: 0o755 });
      fs.writeFileSync(path.join(p.codex, 'thread-writer-locks', '.coordination.lock'), '', { mode: 0o644 });
      fs.writeFileSync(path.join(p.codex, 'thread-writer-locks', '00000000-0000-7000-8000-000000000001.lock'), '', { mode: 0o644 });
      assert.deepEqual(preflight(p), {});
      assert.deepEqual(prepareProfile(path.dirname(p.root)), p);
      fs.writeFileSync(path.join(p.codex, 'config.toml'), 'synthetic contamination', { mode: 0o600 });
      assert.throws(() => preflight(p), { code: 'unsafeProfile' });
    });
    await test('new runtime allowances refuse unsafe types modes links and contents', () => {
      const artifactProfile = () => {
        const p = prepareProfile(fresh());
        fs.mkdirSync(path.join(p.codex, 'thread-writer-locks'), { mode: 0o755 });
        return p;
      };
      for (const relative of ['.sandbox_migration', 'thread-writer-locks/.coordination.lock',
        'thread-writer-locks/00000000-0000-7000-8000-000000000001.lock']) {
        for (const kind of ['directory', 'symlink', 'hardlink', 'oversized', 'writable', 'executable']) {
          const p = artifactProfile(), file = path.join(p.codex, relative);
          if (kind === 'directory') fs.mkdirSync(file, { mode: 0o700 });
          else if (kind === 'symlink') fs.symlinkSync(p.registry, file);
          else if (kind === 'hardlink') fs.linkSync(p.registry, file);
          else {
            fs.writeFileSync(file, kind === 'oversized' ? 'x'.repeat(65) : '', { mode: 0o600 });
            if (kind === 'writable') fs.chmodSync(file, 0o622);
            if (kind === 'executable') fs.chmodSync(file, 0o700);
          }
          assert.throws(() => preflight(p), { code: 'unsafeProfile' }, `${relative}: ${kind}`);
        }
      }
      for (const name of ['config.toml', 'auth.json', 'AGENTS.md', 'skills', 'hooks', 'plugins', 'arbitrary.lock',
        '00000000-0000-7000-8000-000000000001.lock.toml', '00000000-0000-7000-8000-00000000000.lock']) {
        const p = artifactProfile();
        fs.writeFileSync(path.join(p.codex, 'thread-writer-locks', name), '', { mode: 0o600 });
        assert.throws(() => preflight(p), { code: 'unsafeProfile' });
      }
      const readableMarker = artifactProfile();
      fs.writeFileSync(path.join(readableMarker.codex, '.sandbox_migration'), '', { mode: 0o600 });
      fs.chmodSync(path.join(readableMarker.codex, '.sandbox_migration'), 0o644);
      assert.throws(() => preflight(readableMarker), { code: 'unsafeProfile' });
      const nonemptyLock = artifactProfile();
      fs.writeFileSync(path.join(nonemptyLock.codex, 'thread-writer-locks', '.coordination.lock'), 'x', { mode: 0o600 });
      assert.throws(() => preflight(nonemptyLock), { code: 'unsafeProfile' });
      for (const kind of ['writable', 'symlink', 'file']) {
        const p = prepareProfile(fresh()), directory = path.join(p.codex, 'thread-writer-locks');
        if (kind === 'symlink') fs.symlinkSync(p.home, directory);
        else if (kind === 'file') fs.writeFileSync(directory, '', { mode: 0o600 });
        else { fs.mkdirSync(directory, { mode: 0o755 }); fs.chmodSync(directory, 0o777); }
        assert.throws(() => preflight(p), { code: 'unsafeProfile' });
      }
    });
    await test('launch pins official provider keychain and disabled tools', () => {
      const args = launchArguments().join(' ');
      assert(args.includes('cli_auth_credentials_store="keyring"')); assert(args.includes('model_provider="openai"'));
      assert(!args.includes('base_url')); assert(!args.includes('api_key='));
      for (const n of ['shell_tool', 'unified_exec', 'browser_use', 'plugins', 'multi_agent']) assert(args.includes(`--disable ${n}`));
    });
    await test('native thread history database created during thread start permits turn and restart', async () => {
      const { runtime, events } = synthetic();
      runtime.onRPC = async method => {
        if (method === 'thread/start') {
          for (const suffix of ['', '-wal', '-shm']) {
            fs.writeFileSync(path.join(runtime.profile.codex, `thread_history_1.sqlite${suffix}`), '', { mode: 0o600 });
          }
        }
      };
      await runtime.execute();
      assert(events.some(e => e.event === 'completed' && e.state === 'completed'));
      assert.deepEqual(preflight(runtime.profile), { 'owned-synthetic-id': 'created' });
      const next = synthetic({ operation: 'status', profileDirectory: runtime.request.profileDirectory });
      assert.equal((await next.runtime.execute()).authenticated, true);
      fs.writeFileSync(path.join(runtime.profile.codex, 'thread_history_2.sqlite'), '', { mode: 0o600 });
      assert.throws(() => preflight(runtime.profile), { code: 'unsafeProfile' });
    });
    await test('thread history database still refuses symbolic and hard links', () => {
      const linked = prepareProfile(fresh());
      fs.symlinkSync('/synthetic/untrusted', path.join(linked.codex, 'thread_history_1.sqlite'));
      assert.throws(() => preflight(linked), { code: 'unsafeProfile' });
      const hard = prepareProfile(fresh());
      const target = path.join(hard.codex, 'thread_history_1.sqlite');
      fs.writeFileSync(target, '', { mode: 0o600 });
      fs.linkSync(target, path.join(root, 'synthetic-hard-link'));
      assert.throws(() => preflight(hard), { code: 'unsafeProfile' });
    });
    await test('new thread persistence acknowledgement precedes turn', async () => {
      let acknowledge; const ack = new Promise(resolve => { acknowledge = resolve; });
      const { runtime, events } = synthetic({}, () => ack); const work = runtime.execute();
      while (!events.some(e => e.event === 'threadCreated')) await new Promise(resolve => setImmediate(resolve));
      assert.equal(preflight(runtime.profile)['owned-synthetic-id'], 'created');
      assert(!runtime.calls.some(c => c.method === 'turn/start')); acknowledge(); await work;
      assert.deepEqual(events.find(e => e.event === 'completed'), { event: 'completed', state: 'completed', inputTokens: 4, outputTokens: 3 });
    });
    await test('delivery acknowledgement precedes turn/start', async () => {
      const asked = []; let release; const held = new Promise(resolve => { release = resolve; });
      const { runtime, events } = synthetic({}, id => { asked.push(id); return id.startsWith('delivery:') ? held : Promise.resolve(); });
      const work = runtime.execute();
      while (!events.some(e => e.event === 'deliveryAttempt')) await new Promise(resolve => setImmediate(resolve));
      assert(!runtime.calls.some(c => c.method === 'turn/start'));
      release(); await work;
      assert(runtime.calls.some(c => c.method === 'turn/start'));
      assert(asked.some(id => id === 'delivery:owned-synthetic-id'));
    });
    await test('refused delivery acknowledgement never sends the prompt', async () => {
      const { runtime } = synthetic({}, id => id.startsWith('delivery:') ? Promise.reject(new Error('Synthetic refusal.')) : Promise.resolve());
      await assert.rejects(runtime.execute()); assert(!runtime.calls.some(c => c.method === 'turn/start'));
    });
    await test('failed persistence callback prevents first send', async () => {
      const { runtime } = synthetic({}, () => Promise.reject(new Error('Synthetic persistence failure.')));
      await assert.rejects(runtime.execute()); assert(!runtime.calls.some(c => c.method === 'turn/start'));
    });
    await test('arbitrary native import rejected before launch', async () => {
      const { runtime } = synthetic({ sessionID: 'native-import' }); await assert.rejects(runtime.execute(), { code: 'ownership' }); assert.equal(runtime.calls.length, 0);
    });
    await test('owned resume uses same ID and strict controls', async () => {
      const { runtime } = synthetic(); await runtime.execute();
      const resumed = synthetic({ profileDirectory: runtime.request.profileDirectory, sessionID: 'owned-synthetic-id' });
      await resumed.runtime.execute(); assert(!resumed.runtime.calls.some(c => c.method === 'thread/start'));
      const resume = resumed.runtime.calls.find(c => c.method === 'thread/resume').params;
      assert.equal(resume.permissions, 'aitvaras_text_only'); assert.equal(resume.threadId, 'owned-synthetic-id'); assert.deepEqual(resume.runtimeWorkspaceRoots, []);
    });
    await test('scoped dynamic tools preserve native isolation and bind resume scope', async () => {
      const projectRoots = ['/synthetic/approved/project'];
      const { runtime } = synthetic({ projectRoots }); await runtime.execute();
      const start = runtime.calls.find(c => c.method === 'thread/start').params;
      assert.deepEqual(start.dynamicTools.map(t => t.name), ['aitvaras_project']);
      assert.deepEqual(start.dynamicTools[0].tools.map(t => t.name), ['list', 'read']);
      assert(start.dynamicTools[0].tools.every(t => t.type === 'function' && t.inputSchema.additionalProperties === false));
      assert.equal(start.permissions, 'aitvaras_text_only'); assert.deepEqual(start.runtimeWorkspaceRoots, []);
      const same = synthetic({ profileDirectory: runtime.request.profileDirectory, sessionID: 'owned-synthetic-id', projectRoots });
      await same.runtime.execute();
      for (const changed of [[], ['/synthetic/approved/other'], [...projectRoots, '/synthetic/approved/other']]) {
        const other = synthetic({ profileDirectory: runtime.request.profileDirectory, sessionID: 'owned-synthetic-id', projectRoots: changed });
        await assert.rejects(other.runtime.execute(), { code: 'ownership' }); assert.equal(other.runtime.calls.length, 0);
      }
      const empty = synthetic(); await empty.runtime.execute();
      assert.deepEqual(empty.runtime.calls.find(c => c.method === 'thread/start').params.dynamicTools, []);
    });
    await test('dynamic request bridge permits only exact scoped calls and bounded replies', async () => {
      const { runtime, events } = synthetic({ projectRoots: ['/synthetic/approved/project'] });
      const writes = []; runtime.child = { stdin: { write(value) { writes.push(JSON.parse(value)); } } };
      runtime.threadID = 'owned-id'; runtime.turnID = 'turn-id';
      const call = { id: 7, method: 'item/tool/call', params: { threadId: 'owned-id', turnId: 'turn-id', callId: 'call-id', namespace: 'aitvaras_project', tool: 'read', arguments: { root: 0, path: 'README.md' } } };
      runtime.serverRequest(call);
      assert.deepEqual(events.at(-1), { event: 'projectToolRequest', id: 'project-1', tool: 'aitvaras_project_read', arguments: { root: 0, path: 'README.md' } });
      runtime.projectToolResult({ command: 'projectToolResult', id: 'project-1', success: true, text: 'synthetic file content' });
      assert.deepEqual(writes.at(-1), { id: 7, result: { success: true, contentItems: [{ type: 'inputText', text: 'synthetic file content' }] } });
      assert(!JSON.stringify(events).includes('synthetic file content'));
      assert.throws(() => runtime.projectToolResult({ command: 'projectToolResult', id: 'project-1', success: true, text: 'duplicate' }));
      for (const mutate of [c => c.method = 'item/commandExecution/requestApproval', c => c.params.tool = 'shell',
        c => c.params.namespace = 'untrusted', c => c.params.threadId = 'other', c => c.params.turnId = 'other',
        c => c.params.arguments.extra = true, c => c.params.arguments.root = 1]) {
        const bad = structuredClone(call); mutate(bad); assert.throws(() => runtime.serverRequest(bad), { code: 'serverRequest' });
      }
      assert.throws(() => runtime.serverRequest(call), { code: 'malformed' });
      runtime.serverRequest({ ...call, id: 8, params: { ...call.params, callId: 'call-id-2' } });
      assert.throws(() => runtime.projectToolResult({ command: 'projectToolResult', id: 'project-2', success: true, text: 'x'.repeat(65537) }));
      runtime.interruptRequested = true;
      runtime.projectToolResult({ command: 'projectToolResult', id: 'project-2', success: true, text: 'discard after stop' });
      assert.equal(writes.length, 1);
      assert.throws(() => runtime.serverRequest(call));
      const textOnly = synthetic().runtime; textOnly.threadID = 'owned-id'; textOnly.turnID = 'turn-id';
      assert.throws(() => textOnly.serverRequest(call), { code: 'serverRequest' });
    });
    await test('dynamic notification never admits unknown tools or other actions', () => {
      const { runtime } = synthetic({ projectRoots: ['/synthetic/approved/project'] });
      runtime.threadID = 'owned-id'; runtime.turnID = 'turn-id';
      const params = { threadId: 'owned-id', turnId: 'turn-id', item: { type: 'dynamicToolCall', namespace: 'aitvaras_project', tool: 'list' } };
      runtime.notification('item/started', params);
      assert.throws(() => runtime.notification('item/started', { ...params, item: { type: 'dynamicToolCall', tool: 'shell' } }));
      assert.throws(() => runtime.notification('item/started', { ...params, item: { type: 'mcpToolCall' } }));
    });
    await test('early interrupt prevents provider send', async () => {
      const { runtime } = synthetic(); runtime.onRPC = async method => { if (method === 'initialize') await runtime.interrupt(); };
      await assert.rejects(runtime.execute()); assert(!runtime.calls.some(c => c.method === 'turn/start'));
    });
    await test('request and stop in one input chunk never launch', async () => {
      const profile = fresh();
      const child = spawn(process.execPath, [helper], { env: { PATH: '/usr/bin:/bin' }, stdio: ['pipe', 'pipe', 'ignore'] });
      let output = '';
      child.stdout.on('data', chunk => { output += chunk; assert(output.length < 65536); });
      const timer = setTimeout(() => child.kill('SIGKILL'), 5000);
      child.stdin.write(JSON.stringify({ operation: 'status', executable: '/synthetic/must-not-launch', profileDirectory: profile }) + '\n' + JSON.stringify({ command: 'interrupt' }) + '\n');
      await new Promise(resolve => child.once('close', resolve));
      clearTimeout(timer);
      const events = output.trim().split('\n').filter(Boolean).map(line => JSON.parse(line));
      assert(events.some(event => event.event === 'error' && event.code === 'cancelled'));
      assert(!events.some(event => event.event === 'processGroup'));
      assert.deepEqual(fs.readdirSync(profile), []);
    });
    await test('interrupt RPC does not fabricate terminal acknowledgement', async () => {
      const { runtime, events } = synthetic(); runtime.hold = true; const work = runtime.execute();
      while (!runtime.turnID) await new Promise(resolve => setImmediate(resolve));
      await runtime.interrupt(); assert(!events.some(e => e.event === 'completed'));
      runtime.notification('turn/completed', { threadId: runtime.threadID, turn: { id: runtime.turnID, status: 'interrupted' } });
      await work; assert.equal(events.find(e => e.event === 'completed').state, 'interrupted');
    });
    await test('failed terminal state preserved', async () => {
      const { runtime, events } = synthetic(); runtime.endState = 'failed'; await runtime.execute(); assert.equal(events.find(e => e.event === 'completed').state, 'failed');
    });
    await test('model mismatch never falls back', async () => {
      const { runtime } = synthetic({ model: 'missing-model' }); await assert.rejects(runtime.execute(), { code: 'modelUnavailable' }); assert(!runtime.calls.some(c => c.method === 'thread/start'));
    });
    await test('action items rejected and bounded text enforced', () => {
      const { runtime } = synthetic(); runtime.threadID = 'owned-id'; runtime.turnID = 'turn-id';
      assert.throws(() => runtime.notification('item/started', { threadId: runtime.threadID, item: { type: 'commandExecution' } }), { code: 'serverRequest' });
      assert.throws(() => runtime.notification('item/agentMessage/delta', { threadId: runtime.threadID, turnId: runtime.turnID, delta: 'x'.repeat(1024 * 1024 + 1) }));
    });
    await test('status preserves actual quota metadata', async () => {
      const { runtime } = synthetic({ operation: 'status' }); const result = await runtime.execute(); assert.equal(result.authenticated, true);
      assert(result.usageSummary.includes('75% remaining')); assert(result.usageSummary.includes('300 min'));
      assert.deepEqual(result.usageWindows, [{ usedPercent: 25, durationMinutes: 300, resetsAt: 2000000000 }]);
    });
    await test('context meter uses last request tokens and actual model window only', () => {
      const { runtime, events } = synthetic(); runtime.threadID = 'owned-id'; runtime.turnID = 'turn-id';
      const params = { threadId: 'owned-id', turnId: 'turn-id', tokenUsage: { last: { inputTokens: 30, outputTokens: 12, totalTokens: 42 }, total: { totalTokens: 9000 }, modelContextWindow: 200 } };
      runtime.notification('thread/tokenUsage/updated', params);
      assert.deepEqual(events.at(-1), { event: 'contextUsage', usedTokens: 42, limitTokens: 200 });
      delete params.tokenUsage.modelContextWindow; delete params.tokenUsage.last.totalTokens;
      runtime.notification('thread/tokenUsage/updated', params);
      assert.deepEqual(events.at(-1), { event: 'contextUsage', usedTokens: null, limitTokens: null });
      params.tokenUsage.modelContextWindow = -1;
      assert.throws(() => runtime.notification('thread/tokenUsage/updated', params), { code: 'malformed' });
    });
    await test('quota service rejection stays unavailable without disabling catalog', async () => {
      const { runtime } = synthetic({ operation: 'status' }); runtime.noQuota = true;
      const result = await runtime.execute();
      assert.equal(result.authenticated, true); assert.equal(result.models[0].id, 'synthetic-model');
      assert(result.usageSummary.includes('unavailable')); assert(!result.usageSummary.includes('0%'));
      assert.equal(result.usageWindows, null);
      assert(!runtime.calls.some(call => call.method === 'turn/start'));
    });
    await test('sign-in confirms persistence without leaking native failure details', async () => {
      const good = synthetic({ operation: 'login' }); await good.runtime.execute();
      assert(good.events.some(event => event.event === 'loginCompleted' && event.success));
      const bad = synthetic({ operation: 'login' }); bad.runtime.loginFails = true;
      await assert.rejects(bad.runtime.execute(), { code: 'keychainUnavailable' });
      assert(!bad.events.some(event => event.event === 'loginCompleted'));
      assert(!JSON.stringify(bad.events).includes('Synthetic keychain persistence failure'));
      assert(!bad.runtime.calls.some(call => call.method === 'turn/start'));
    });
    console.log(JSON.stringify({ passed, providerRequests: 0, realAuthentication: false }));
  }
} finally {
  for (const fixture of homeFixtures) fs.rmSync(fixture, { recursive: true, force: true });
  fs.rmSync(root, { recursive: true, force: true });
}
