// Manual macOS compatibility proof. No login, credentials or live model service.
// Usage: node scripts/check-codex-text-isolation.mjs /absolute/path/to/codex
// The synthetic provider is test-only and must never become a runtime fallback.
import http from 'node:http';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, rmSync, realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { launchPolicy, projectTools } from '../Sources/AitvarasConnectors/Resources/codex-interactive.mjs';

const executable = process.argv[2];
if (process.platform !== 'darwin' || !executable || !path.isAbsolute(executable)) {
  throw new Error('macOS and an explicit absolute Codex executable are required.');
}
const root = mkdtempSync(path.join(tmpdir(), 'aitvaras-codex-isolation-'));
const marker = 'AITVARAS_SYNTHETIC_PRIVATE_CONTEXT_CANARY';
const disabled = ['apps', 'hooks', 'plugins', 'remote_plugin', 'shell_tool', 'shell_snapshot',
  'shell_snapshot_v2', 'unified_exec', 'view_image', 'image_generation', 'browser_use',
  'browser_use_external', 'browser_use_full_cdp_access', 'computer_use', 'code_mode',
  'code_mode_host', 'code_mode_prewarm', 'multi_agent', 'multi_agent_v2', 'memories',
  'skill_search', 'skill_mcp_dependency_install', 'request_permissions_tool', 'tool_suggest',
  'workspace_dependencies', 'realtime_conversation', 'goals', 'sleep_tool',
  'enable_request_compression', 'api_key_model_discovery'];
const assert = (condition, message) => { if (!condition) throw new Error(message); };

async function scenario(name, attack, contaminated, shieldHome = false) {
  const directProject = name.startsWith('direct-project-');
  const model = directProject ? 'gpt-6.1-sol' : 'gpt-5.4';
  let projectCalls = 0;
  const directory = path.join(root, name);
  const home = path.join(directory, 'home'), codexHome = path.join(directory, 'codex');
  const cwd = path.join(directory, 'project'), temporary = path.join(directory, 'tmp');
  for (const dir of [home, codexHome, cwd, temporary]) mkdirSync(dir, { recursive: true, mode: 0o700 });
  writeFileSync(path.join(cwd, 'AGENTS.md'), marker + '_PROJECT');
  if (contaminated) {
    if (!shieldHome) writeFileSync(path.join(codexHome, 'AGENTS.md'), marker + '_GLOBAL');
    const skill = path.join(home, '.agents', 'skills', 'synthetic-canary');
    mkdirSync(skill, { recursive: true });
    writeFileSync(path.join(skill, 'SKILL.md'), `---\nname: synthetic-canary\ndescription: ${marker}_SKILL\n---\nSynthetic private instructions.\n`);
  }
  const env = { HOME: home, CODEX_HOME: codexHome, TMPDIR: temporary,
    PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8' };
  const version = execFileSync(executable, ['--version'], { env, encoding: 'utf8', timeout: 5000 }).trim();
  let captured, toolOutput, completed, child, buffer = '', sequence = 0, failure;
  let calls = 0, bytes = 0;
  const pending = new Map();
  const server = http.createServer(async (request, response) => {
    try {
      assert(request.method === 'POST' && request.url === '/v1/responses', 'Unexpected synthetic route.');
      assert(!request.headers.authorization, 'Unexpected credential on synthetic request.');
      const chunks = [];
      for await (const chunk of request) {
        bytes += chunk.length;
        assert(bytes < 8 * 1024 * 1024, 'Synthetic request too large.');
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      captured ??= input;
      toolOutput = input.input?.find(item => item.type === 'function_call_output')?.output ?? toolOutput;
      calls++;
      assert(calls <= 3, 'Unexpected provider retry.');
      const item = attack === 'spawn_agent' && calls === 1
        ? { type: 'function_call', id: 'fc_agent', call_id: 'call_agent', namespace: 'collaboration', name: 'spawn_agent',
            arguments: JSON.stringify({ task_name: 'synthetic_probe', message: 'Synthetic fixture only.', fork_turns: 'none' }) }
        : directProject && calls === 1
        ? { type: 'function_call', id: 'fc_project', call_id: 'call_project', namespace: 'aitvaras_project', name: 'read',
            arguments: JSON.stringify({ root: 0, path: 'example.txt' }) }
        : attack && calls === 1
        ? { type: 'function_call', id: 'fc_synthetic', call_id: 'call_synthetic', name: attack,
            arguments: JSON.stringify({ cmd: `/usr/bin/touch ${path.join(directory, 'unexpected-effect')}`,
              path: path.join(cwd, 'AGENTS.md') }) }
        : { type: 'message', id: 'msg_synthetic', status: 'completed', role: 'assistant',
            content: [{ type: 'output_text', text: 'Synthetic reply.', annotations: [] }] };
      response.writeHead(200, { 'Content-Type': 'text/event-stream' });
      const emit = data => response.write(`event: ${data.type}\ndata: ${JSON.stringify(data)}\n\n`);
      emit({ type: 'response.created', response: { id: 'resp_synthetic', status: 'in_progress', output: [] } });
      emit({ type: 'response.output_item.added', output_index: 0, item: { ...item, status: 'in_progress', content: [] } });
      if (item.type === 'message') emit({ type: 'response.output_text.delta', item_id: item.id,
        output_index: 0, content_index: 0, delta: 'Synthetic reply.' });
      emit({ type: 'response.output_item.done', output_index: 0, item });
      emit({ type: 'response.completed', response: { id: 'resp_synthetic', status: 'completed',
        output: [item], usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 } } });
      response.end();
    } catch (error) { failure = error; response.writeHead(500); response.end('{}'); }
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const overrides = [
    'model_provider="synthetic_fixture"', `model=${JSON.stringify(model)}`,
    'features.code_mode={enabled=false,direct_only_tool_namespaces=["aitvaras_project"]}',
    'features.multi_agent_v2={enabled=false,disable_native_tools=true}',
    `model_providers.synthetic_fixture={name="Local fixture",base_url="http://127.0.0.1:${server.address().port}/v1",wire_api="responses",requires_openai_auth=false,supports_websockets=false,request_max_retries=0,stream_max_retries=0}`,
    'web_search="disabled"', 'analytics.enabled=false', 'feedback.enabled=false',
    'features.skip_host_skill_discovery=true', 'project_doc_max_bytes=0', 'developer_instructions=""',
    'skills.bundled.enabled=false', 'memories.use_memories=false', 'memories.generate_memories=false',
    'default_permissions="aitvaras_text_only"',
    'permissions.aitvaras_text_only.filesystem={":root"="deny",":minimal"="read"}',
    'permissions.aitvaras_text_only.network.enabled=false', 'approval_policy="never"',
    'approvals_reviewer="user"', 'chatgpt_base_url="http://127.0.0.1:1"'
  ];
  const seatbelt = (shieldHome ? launchPolicy({ root: realpathSync(codexHome), codex: realpathSync(codexHome) }, realpathSync(home)) : '(version 1)(allow default)') +
    '(deny network*)(allow network-outbound (remote ip "localhost:*"))(allow network-inbound (local ip "localhost:*"))';
  const deadline = setTimeout(() => { failure = new Error('Native fixture timed out.'); if (child) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } }, 25000);
  try {
    child = spawn('/usr/bin/sandbox-exec', ['-p', seatbelt, executable, 'app-server', '--stdio',
      ...disabled.flatMap(flag => ['--disable', flag]), ...overrides.flatMap(value => ['-c', value])],
    { env, cwd, detached: true, stdio: ['pipe', 'pipe', 'ignore'] });
    child.stdin.on('error', () => {});
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', chunk => {
      buffer += chunk;
      if (buffer.length > 2 * 1024 * 1024) { failure = new Error('Native response too large.'); return; }
      for (;;) {
        const end = buffer.indexOf('\n'); if (end < 0) break;
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        let event; try { event = JSON.parse(line); } catch { failure = new Error('Malformed native frame.'); continue; }
        if (pending.has(event.id)) {
          const request = pending.get(event.id); pending.delete(event.id);
          event.error ? request.reject(new Error('Native RPC rejected fixture.')) : request.resolve(event.result);
        } else if (event.method === 'turn/completed') completed = event.params.turn;
        else if (directProject && event.method === 'item/tool/call' && event.id !== undefined) {
          const p = event.params;
          assert(p.namespace === 'aitvaras_project' && p.tool === 'read'
            && p.arguments.root === 0 && p.arguments.path === 'example.txt', 'Unexpected project capability.');
          projectCalls++;
          child.stdin.write(JSON.stringify({ id: event.id, result: {
            contentItems: [{ type: 'inputText', text: 'SYNTHETIC_PROJECT_RESULT' }], success: true } }) + '\n');
        }
        else if (event.id !== undefined && event.method) {
          failure = new Error('Unexpected server request.');
        }
      }
    });
    const rpc = (method, params) => new Promise((resolve, reject) => {
      const id = ++sequence; pending.set(id, { resolve, reject });
      child.stdin.write(JSON.stringify({ id, method, params }) + '\n');
      const timer = setTimeout(() => reject(new Error('Native RPC timeout.')), 10000); timer.unref();
    });
    await rpc('initialize', { clientInfo: { name: 'aitvaras_isolated_proof', version: '0' }, capabilities: { experimentalApi: true } });
    child.stdin.write(JSON.stringify({ method: 'initialized', params: {} }) + '\n');
    const started = await rpc('thread/start', { cwd, model, modelProvider: 'synthetic_fixture',
      ephemeral: true, permissions: 'aitvaras_text_only', approvalPolicy: 'never', approvalsReviewer: 'user',
      environments: [], runtimeWorkspaceRoots: [], selectedCapabilityRoots: [], dynamicTools: directProject ? projectTools([cwd]) : [],
      baseInstructions: 'AITVARAS_SYNTHETIC_APPROVED_BASE', developerInstructions: '', allowProviderModelFallback: false });
    await rpc('turn/start', { threadId: started.thread.id, input: [{ type: 'text', text: 'Synthetic greeting.' }],
      permissions: 'aitvaras_text_only', approvalPolicy: 'never' });
    const until = Date.now() + 10000;
    while (!completed && !failure && Date.now() < until) await new Promise(resolve => setTimeout(resolve, 20));
    if (failure) throw failure;
    assert(completed?.status === 'completed', 'Missing successful terminal event.');
    const exposedTools = captured.tools ?? captured.input?.filter(item => item.type === 'additional_tools').flatMap(item => item.tools) ?? [];
    if (directProject) {
      const namespace = exposedTools.find(tool => tool.name === 'aitvaras_project');
      assert(namespace?.type === 'namespace' && JSON.stringify(namespace.tools.map(tool => tool.name)) === '["list","read"]', 'Project tools not directly exposed.');
      if (!attack) assert(projectCalls === 1 && typeof toolOutput === 'string' && toolOutput.includes('SYNTHETIC_PROJECT_RESULT'), 'Direct project tool bridge failed.');
      assert(!exposedTools.some(tool => ['exec_command', 'shell', 'apply_patch'].includes(tool.name)), 'Unexpected native capability.');
      assert(!exposedTools.some(tool => tool.name === 'collaboration'), 'Native agent tools remain exposed.');
    } else assert(JSON.stringify(exposedTools.map(tool => tool.name)) === '["request_user_input"]', 'Tool inventory changed; stop and review.');
    const wire = JSON.stringify(captured);
    assert(wire.includes('AITVARAS_SYNTHETIC_APPROVED_BASE'), 'Approved base context missing.');
    assert(contaminated && !shieldHome ? wire.includes(marker + '_GLOBAL') : !wire.includes(marker), 'Context isolation negative control failed.');
    if (attack) assert(typeof toolOutput === 'string' && toolOutput.includes(`unsupported call: ${attack === 'spawn_agent' ? 'collaborationspawn_agent' : attack}`), 'Fabricated tool was not rejected.');
    assert(!existsSync(path.join(directory, 'unexpected-effect')), 'Unexpected tool side effect.');
    return { scenario: name, version, passed: true, projectCalls, providerRequests: calls };
  } finally {
    clearTimeout(deadline);
    if (child) {
      try { process.kill(-child.pid, 'SIGKILL'); } catch {}
      if (child.exitCode === null && child.signalCode === null) await new Promise(resolve => child.once('close', resolve));
    }
    server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  }
}

try {
  for (const [name, attack, contaminated, shieldHome] of [
    ['clean-context', null, false], ['contaminated-negative-control', null, true],
    ['reject-shell', 'exec_command', false], ['reject-file', 'read_file', false],
    ['shielded-native-home', null, true, true], ['direct-project-functions', null, false],
    ['direct-project-reject-agent', 'spawn_agent', false]
  ]) console.log(JSON.stringify(await scenario(name, attack, contaminated, shieldHome)));
} finally { rmSync(root, { recursive: true, force: true }); }
