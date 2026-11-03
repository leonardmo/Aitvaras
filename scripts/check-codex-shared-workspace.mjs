// Disposable native protocol proof: fixed local responses, no authentication or live model.
// The synthetic provider is test-only and must never be a runtime fallback.
// Usage: node scripts/check-codex-shared-workspace.mjs /absolute/path/to/codex
import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { setTimeout as delay } from 'node:timers/promises';

const executable = process.argv[2];
if (process.platform !== 'darwin' || !path.isAbsolute(executable ?? '')) throw Error('Explicit macOS Codex executable required.');
// macOS Unix sockets have a short path limit; the per-user temp path can exceed it.
const root = fs.realpathSync(fs.mkdtempSync('/private/tmp/aitvaras-shared-'));
const children = [];
const connections = [];
const assert = (value, message) => { if (!value) throw Error(message); };
const folders = ['home', 'profile', 'project-a', 'project-b', 'project-c', 'tmp'];
for (const name of folders) fs.mkdirSync(path.join(root, name), { mode: 0o700 });
const roots = ['project-a', 'project-b'].map(name => ({ path: path.join(root, name) }));
const env = { HOME: path.join(root, 'home'), CODEX_HOME: path.join(root, 'profile'), TMPDIR: path.join(root, 'tmp'),
  PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' };
let providerRequests = 0, providerFailure;
const provider = http.createServer(async (request, response) => {
  try {
    assert(request.method === 'POST' && request.url === '/v1/responses' && !request.headers.authorization, 'Unexpected synthetic provider request.');
    let bytes = 0; for await (const chunk of request) { bytes += chunk.length; assert(bytes <= 2 * 1024 * 1024, 'Oversized synthetic request.'); }
    assert(++providerRequests <= 2, 'Unexpected provider retry.');
    const id = `fixture-${providerRequests}`;
    const item = { type: 'message', id: `msg-${id}`, status: 'completed', role: 'assistant',
      content: [{ type: 'output_text', text: 'Synthetic shared reply.', annotations: [] }] };
    response.writeHead(200, { 'Content-Type': 'text/event-stream' });
    const emit = data => response.write(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);
    emit({ type: 'response.created', response: { id, status: 'in_progress', output: [] } });
    emit({ type: 'response.output_item.added', output_index: 0, item: { ...item, status: 'in_progress', content: [] } });
    emit({ type: 'response.output_text.delta', item_id: item.id, output_index: 0, content_index: 0, delta: 'Synthetic shared reply.' });
    emit({ type: 'response.output_item.done', output_index: 0, item });
    emit({ type: 'response.completed', response: { id, status: 'completed', output: [item], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } });
    response.end();
  } catch (error) { providerFailure = error; response.writeHead(500); response.end('{}'); }
});
await new Promise(resolve => provider.listen(0, '127.0.0.1', resolve));
const overrides = [
  'model_provider="synthetic_fixture"', 'model="gpt-5.4"',
  `model_providers.synthetic_fixture={name="Fixed local fixture",base_url="http://127.0.0.1:${provider.address().port}/v1",wire_api="responses",requires_openai_auth=false,supports_websockets=false,request_max_retries=0,stream_max_retries=0}`,
  'web_search="disabled"', 'analytics.enabled=false', 'feedback.enabled=false',
  'features.skip_host_skill_discovery=true', 'project_doc_max_bytes=0', 'developer_instructions=""',
  'features.multi_agent_v2={enabled=false,disable_native_tools=true}',
  'skills.bundled.enabled=false', 'memories.use_memories=false', 'memories.generate_memories=false',
  'default_permissions="fixture_none"', 'permissions.fixture_none.filesystem={":root"="deny",":minimal"="read"}',
  'permissions.fixture_none.network.enabled=false', 'approval_policy="never"', 'chatgpt_base_url="http://127.0.0.1:1"'
];
const disabled = ['apps', 'hooks', 'plugins', 'remote_plugin', 'shell_tool', 'unified_exec', 'browser_use',
  'computer_use', 'code_mode', 'code_mode_host', 'code_mode_prewarm', 'multi_agent', 'memories', 'api_key_model_discovery'];
const argumentsFor = listen => ['app-server', '--listen', listen, ...disabled.flatMap(name => ['--disable', name]),
  ...overrides.flatMap(value => ['-c', value])];
function launch(args) {
  const policy = '(version 1)(allow default)(deny network*)(allow network-outbound (remote ip "localhost:*"))(allow network-inbound (local ip "localhost:*"))';
  const child = spawn('/usr/bin/sandbox-exec', ['-p', policy, executable, ...args],
    { env, cwd: path.join(root, 'home'), detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
  children.push(child); child.stdin.on('error', () => {});
  // Drain native diagnostics without retaining or printing their contents.
  child.stderr.on('data', () => {});
  return child;
}
class Client {
  sequence = 0; pending = new Map(); events = [];
  constructor(connection) {
    this.connection = connection;
    connection.addEventListener('message', event => {
        const line = event.data;
        if (typeof line !== 'string' || line.length > 2 * 1024 * 1024) { this.fail(); return; }
        let value; try { value = JSON.parse(line); } catch { this.fail(); return; }
        const request = this.pending.get(value.id);
        if (request) {
          clearTimeout(request.timer); this.pending.delete(value.id);
          value.error ? request.reject(Error(`Native ${request.method} rejected (${value.error.code}): ${String(value.error.message).replaceAll(root, '<synthetic>').slice(0, 300)}`)) : request.resolve(value.result);
        } else if (value.method && value.id == null) {
          this.events.push(value); if (this.events.length > 1000) this.fail();
        } else if (value.method) { this.fail(); }
    });
    connection.addEventListener('error', () => this.fail()); connection.addEventListener('close', () => this.fail());
  }
  fail() { for (const request of this.pending.values()) { clearTimeout(request.timer); request.reject(Error('Native connection unavailable.')); } this.pending.clear(); }
  rpc(method, params) {
    const id = ++this.sequence;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(Error('Native operation timed out.')); }, 5000);
      this.pending.set(id, { resolve, reject, timer, method });
      this.connection.send(JSON.stringify({ id, method, params }));
    });
  }
  async initialize() {
    await this.rpc('initialize', { clientInfo: { name: 'aitvaras_shared_fixture', version: '0' }, capabilities: { experimentalApi: true } });
    this.connection.send(JSON.stringify({ method: 'initialized', params: {} }));
  }
}
async function connect(url) {
  const until = Date.now() + 5000;
  while (Date.now() < until) {
    const connection = new WebSocket(url);
    const opened = await new Promise(resolve => {
      connection.addEventListener('open', () => resolve(true), { once: true });
      connection.addEventListener('error', () => resolve(false), { once: true });
    });
    if (opened) { connections.push(connection); return new Client(connection); }
    connection.close(); await delay(20);
  }
  throw Error('Shared loopback listener unavailable.');
}
async function completeTurn(client, threadId, message) {
  const started = await client.rpc('turn/start', { threadId, input: [{ type: 'text', text: message }],
    permissions: 'fixture_none', approvalPolicy: 'never' });
  const until = Date.now() + 5000;
  while (!client.events.some(event => event.method === 'turn/completed' && event.params.turn.id === started.turn.id)
    && !providerFailure && Date.now() < until) await delay(20);
  if (providerFailure) throw providerFailure;
  assert(client.events.some(event => event.method === 'turn/completed' && event.params.turn.id === started.turn.id
    && event.params.turn.status === 'completed'), 'Synthetic native turn did not complete.');
}
const deadline = setTimeout(() => { for (const child of children) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } }, 25000);
try {
  const reservation = net.createServer();
  await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const url = `ws://127.0.0.1:${port}`;
  const server = launch(argumentsFor(url)); server.stdout.resume();
  const first = await connect(url);
  const second = await connect(url);
  await first.initialize(); await second.initialize();
  const created = await first.rpc('project/create', { idempotencyKey: 'synthetic-shared-project', name: 'Synthetic shared project', roots, metadata: { fixture: 'synthetic' } });
  const project = created.project;
  assert(project?.id && JSON.stringify(project.roots) === JSON.stringify(roots), 'Project roots/order changed.');
  const observed = await second.rpc('project/read', { projectId: project.id });
  assert(observed.project.id === project.id && observed.project.name === project.name, 'Second client sees another project.');
  const updatedRoots = [roots[1], { path: path.join(root, 'project-c') }];
  await second.rpc('project/update', { projectId: project.id, name: 'Synthetic renamed project', roots: updatedRoots });
  const updated = await first.rpc('project/read', { projectId: project.id });
  assert(updated.project.name === 'Synthetic renamed project' && JSON.stringify(updated.project.roots) === JSON.stringify(updatedRoots), 'Project update was not shared.');
  const started = await first.rpc('thread/start', { projectId: project.id, cwd: updatedRoots[1].path,
    model: 'gpt-5.4', modelProvider: 'synthetic_fixture', permissions: 'fixture_none', approvalPolicy: 'never',
    baseInstructions: 'Synthetic protocol fixture only.', developerInstructions: '', dynamicTools: [], environments: [],
    runtimeWorkspaceRoots: updatedRoots.map(value => value.path), allowProviderModelFallback: false });
  const threadID = started.thread?.id;
  assert(threadID && started.thread.projectId === project.id && started.thread.cwd === updatedRoots[1].path, 'Explicit thread cwd/project was not preserved.');
  await completeTurn(first, threadID, 'Synthetic first client message.');
  const resumed = await second.rpc('thread/resume', { threadId: threadID, excludeTurns: true });
  assert(resumed.thread.id === threadID && resumed.thread.projectId === project.id, 'Shared thread identity changed.');
  await completeTurn(second, threadID, 'Synthetic second client message.');
  const firstTurns = await first.rpc('thread/turns/list', { threadId: threadID, limit: 10, sortDirection: 'asc' });
  const secondTurns = await second.rpc('thread/turns/list', { threadId: threadID, limit: 10, sortDirection: 'asc' });
  assert(firstTurns.data.length === 2 && JSON.stringify(firstTurns.data.map(turn => turn.id)) === JSON.stringify(secondTurns.data.map(turn => turn.id)), 'Canonical turn history diverged across clients.');
  await second.rpc('thread/name/set', { threadId: threadID, name: 'Synthetic shared chat' });
  const read = await first.rpc('thread/read', { threadId: threadID, includeTurns: false });
  assert(read.thread.name === 'Synthetic shared chat', 'Native thread name did not propagate.');
  await delay(50);
  assert(first.events.some(event => event.method === 'project/changed' && event.params.projectId === project.id), 'Project events missing on first connection.');
  assert(second.events.some(event => event.method === 'project/changed' && event.params.projectId === project.id), 'Project events missing on second connection.');
  console.log(JSON.stringify({ passed: true, sharedConnections: 2, projectRootsAndOrder: true, projectMutationBothWays: true,
    explicitCwdIndependentOfRootOrder: true, canonicalThreadResume: true, nativeRenameVisible: true,
    projectEventsBothClients: true, canonicalTurnsBothClients: true, syntheticTurns: 2, providerRequests,
    liveProviderRequests: 0, realAuthentication: false, productionProfileChanged: false }));
} finally {
  clearTimeout(deadline);
  for (const connection of connections) connection.close();
  for (const child of children) { try { process.kill(-child.pid, 'SIGTERM'); } catch {} }
  await delay(100);
  for (const child of children) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
  provider.closeAllConnections(); await new Promise(resolve => provider.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });
}
