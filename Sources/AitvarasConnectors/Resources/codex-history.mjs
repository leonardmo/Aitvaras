// Read-only stdio client for the documented Codex app-server protocol.
// https://learn.chatgpt.com/docs/app-server
// Private request data enters stdin, never argv. No native databases are parsed.
import { spawn } from 'node:child_process';

const MAX_WIRE = 4 * 1024 * 1024;
const MAX_OUTPUT = 900 * 1024;
const ALLOWED = new Set(['initialize', 'thread/list', 'thread/read', 'thread/turns/list', 'project/list', 'project/read']);
const TEXT_COVERAGE = 'Text-only stored user and assistant messages; excludes tools, reasoning, attachments and other item types. Local snapshot only; activity in other Codex processes is unknown.';
let child;
let stopping;
let stopSignal = false;
const pending = new Map();
const failure = code => Object.assign(new Error(code), { code });
const validID = x => typeof x === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(x) && !/[^A-Za-z0-9_-]/.test(x);
const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);

async function stopChild() {
  if (stopping) return stopping;
  const target = child;
  if (!target || target.exitCode !== null || target.signalCode !== null) return;
  stopping = new Promise(resolve => {
    const timer = setTimeout(() => target.kill('SIGKILL'), 200);
    target.once('close', () => { clearTimeout(timer); resolve(); });
    target.stdin?.destroy();
    target.kill('SIGTERM');
  });
  await stopping;
}

for (const signal of ['SIGTERM', 'SIGINT']) {
  process.on(signal, () => {
    stopSignal = true;
    // Keep the helper alive until its direct app-server child has been reaped.
    for (const p of pending.values()) p.reject(failure('unavailable'));
    void stopChild().then(() => process.exit(1));
  });
}

function launch(executable, args) {
  if (stopSignal) throw failure('unavailable');
  stopping = undefined;
  child = spawn(executable, args, { stdio: ['pipe', 'pipe', 'ignore'], shell: false });
  child.stdin.on('error', () => {});
  return child;
}

async function version(executable) {
  const proc = launch(executable, ['--version']);
  let data = '';
  return await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { void stopChild(); reject(failure('timeout')); }, 3000);
    proc.stdout.on('data', chunk => { if (data.length < 1024) data += chunk.toString('utf8'); });
    proc.once('error', () => { clearTimeout(timer); reject(failure('unavailable')); });
    proc.once('close', code => {
      clearTimeout(timer);
      if (code !== 0) return reject(failure('unavailable'));
      resolve(data.match(/^codex(?:-cli)?\s+([0-9][A-Za-z0-9.+-]{0,100})\s*$/)?.[1] ?? null);
    });
    proc.stdin.end();
  });
}

function startServer(executable) {
  const proc = launch(executable, ['app-server']);
  let buffer = '';
  let sequence = 0;
  let total = 0;
  const failAll = error => {
    for (const p of pending.values()) { clearTimeout(p.timer); p.reject(error); }
    pending.clear();
  };
  proc.once('error', () => failAll(failure('unavailable')));
  proc.once('close', () => failAll(failure('unavailable')));
  proc.stdout.setEncoding('utf8');
  proc.stdout.on('data', chunk => {
    total += Buffer.byteLength(chunk);
    if (total > MAX_WIRE) { failAll(failure('tooLarge')); void stopChild(); return; }
    buffer += chunk;
    for (;;) {
      const end = buffer.indexOf('\n');
      if (end < 0) break;
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
      if (!line.trim()) continue;
      let message;
      try { message = JSON.parse(line); } catch { failAll(failure('malformed')); void stopChild(); return; }
      // Never answer approvals, tools, auth or any server-initiated request.
      if (message.method && message.id !== undefined) {
        failAll(failure('unsupported')); void stopChild(); return;
      }
      const p = pending.get(message.id);
      if (!p) continue; // Notifications are not transcript evidence.
      pending.delete(message.id); clearTimeout(p.timer);
      if (message.error) {
        // Server error prose may contain private content; preserve only the numeric code internally.
        p.reject(Object.assign(failure(message.error.code === -32601 ? 'unsupported' : 'unavailable'),
                               { rpcCode: message.error.code }));
      } else if (object(message.result)) p.resolve(message.result);
      else p.reject(failure('malformed'));
    }
  });
  return {
    async request(method, params) {
      if (!ALLOWED.has(method)) throw failure('unsupported');
      const id = ++sequence;
      return await new Promise((resolve, reject) => {
        const timer = setTimeout(() => { pending.delete(id); reject(failure('timeout')); }, 7000);
        pending.set(id, { resolve, reject, timer });
        proc.stdin.write(JSON.stringify({ id, method, params }) + '\n');
      });
    },
    initialized() { proc.stdin.write(JSON.stringify({ method: 'initialized', params: {} }) + '\n'); }
  };
}

function cursorFrom(request) {
  if (request.cursor == null) return undefined;
  if (typeof request.cursor !== 'string' || !request.cursor || request.cursor.length > 16384 || /[^A-Za-z0-9_-]/.test(request.cursor))
    throw failure('invalidRequest');
  let value;
  try { value = JSON.parse(Buffer.from(request.cursor, 'base64url').toString('utf8')); }
  catch { throw failure('invalidRequest'); }
  if (value.v !== 1 || value.operation !== request.operation || value.id !== (request.id ?? null)
      || (value.profileNamespace ?? null) !== (request.profileNamespace ?? null)
      || value.archived !== (request.archived === true) || !validRawCursor(value.raw)) throw failure('invalidRequest');
  return value.raw;
}

function validRawCursor(x) {
  return typeof x === 'string' && x.length > 0 && Buffer.byteLength(x) <= 8192 && !/[\u0000-\u001f\u007f]/.test(x);
}

function nextCursor(raw, request) {
  if (raw == null) return null;
  if (!validRawCursor(raw)) throw failure('malformed');
  if (raw === cursorFrom(request)) throw failure('malformed');
  return Buffer.from(JSON.stringify({ v: 1, operation: request.operation, id: request.id ?? null,
    profileNamespace: request.profileNamespace ?? null,
    archived: request.archived === true, raw })).toString('base64url');
}

function projectSnapshot(project, request) {
  if (!object(project) || !validID(project.id) || typeof project.name !== 'string'
      || Buffer.byteLength(project.name) > 4096 || !Array.isArray(project.roots) || project.roots.length > 128
      || !Number.isSafeInteger(project.createdAt) || !Number.isSafeInteger(project.updatedAt)
      || !Number.isSafeInteger(project.position)
      || (project.recencyAt != null && !Number.isSafeInteger(project.recencyAt))
      || !object(project.metadata) || Object.keys(project.metadata).length > 128
      || Object.entries(project.metadata).some(([key, value]) => Buffer.byteLength(key) > 4096
        || typeof value !== 'string' || Buffer.byteLength(value) > 4096)) throw failure('malformed');
  const roots = project.roots.map(root => {
    if (!object(root) || typeof root.path !== 'string' || !root.path.startsWith('/')
        || Buffer.byteLength(root.path) > 4096 || /[\u0000-\u001f\u007f]/.test(root.path)) throw failure('malformed');
    return { path: root.path };
  });
  return { identity: { provider: 'codex', hostID: 'local', profileNamespace: request.profileNamespace,
      externalID: project.id }, name: project.name, roots, createdAt: project.createdAt,
    updatedAt: project.updatedAt, position: project.position, recencyAt: project.recencyAt ?? null,
    metadata: project.metadata };
}

function summary(thread, archived = null) {
  if (!object(thread) || !validID(thread.id)) throw failure('malformed');
  const parent = thread.forkedFromId ?? thread.parentThreadId ?? null;
  const relationship = thread.forkedFromId != null ? 'fork' : thread.parentThreadId != null ? 'spawn' : null;
  if (parent !== null && !validID(parent)) throw failure('malformed');
  return { provider: 'codex', hostID: 'local', externalID: thread.id,
    title: typeof thread.name === 'string' && thread.name.trim() ? thread.name : 'Untitled Codex session',
    directory: typeof thread.cwd === 'string' ? thread.cwd : null,
    updatedAt: Number.isFinite(thread.updatedAt) ? thread.updatedAt : null,
    parentExternalID: parent, parentRelationship: relationship, archived,
    // A separate app-server cannot establish whether another process is idle.
    activity: thread.status?.type === 'active' ? 'Active' : 'Unknown' };
}

function messagesFrom(turns) {
  const messages = [];
  const seen = new Set();
  for (const turn of turns) {
    if (!object(turn) || !Array.isArray(turn.items)) throw failure('malformed');
    for (const item of turn.items) {
      if (item?.type !== 'userMessage' && item?.type !== 'agentMessage') continue;
      if (typeof item.id !== 'string' || !item.id || item.id.length > 512) throw failure('malformed');
      let text;
      if (item.type === 'agentMessage') {
        if (typeof item.text !== 'string') throw failure('malformed');
        text = item.text;
      } else {
        if (!Array.isArray(item.content)) throw failure('malformed');
        if (item.content.some(part => part?.type === 'text' && typeof part.text !== 'string'))
          throw failure('malformed');
        text = item.content.filter(part => part?.type === 'text' && typeof part.text === 'string')
          .map(part => part.text).join('\n');
      }
      if (!text) continue;
      if (seen.has(item.id)) throw failure('malformed');
      seen.add(item.id);
      messages.push({ externalID: item.id, role: item.type === 'userMessage' ? 'user' : 'assistant', text });
    }
  }
  return messages;
}

async function execute(request) {
  if (!object(request) || !['capabilities', 'list', 'read', 'projectCapabilities', 'listProjects', 'readProject'].includes(request.operation)
      || typeof request.executable !== 'string' || !request.executable.startsWith('/')
      || (['read', 'readProject'].includes(request.operation) && !validID(request.id))) throw failure('invalidRequest');
  const projectOperation = ['projectCapabilities', 'listProjects', 'readProject'].includes(request.operation);
  if (projectOperation && !validID(request.profileNamespace)) throw failure('invalidRequest');
  const cursor = cursorFrom(request);
  const cliVersion = ['capabilities', 'projectCapabilities'].includes(request.operation) ? await version(request.executable) : null;
  const server = startServer(request.executable);
  await server.request('initialize', { clientInfo: { name: 'aitvaras_history', version: '1.0.0' },
    capabilities: { experimentalApi: true } });
  server.initialized();
  if (projectOperation) {
    if (request.operation === 'readProject') {
      const response = await server.request('project/read', { projectId: request.id });
      const snapshot = projectSnapshot(response.project, request);
      if (snapshot.identity.externalID !== request.id) throw failure('malformed');
      return snapshot;
    }
    const limit = request.operation === 'projectCapabilities' ? 1 : 50;
    const page = await server.request('project/list', { cursor, limit, sortKey: 'position', sortDirection: 'asc' });
    if (!Array.isArray(page.data) || page.data.length > limit) throw failure('malformed');
    const projects = page.data.map(project => projectSnapshot(project, request));
    if (new Set(projects.map(project => project.identity.externalID)).size !== projects.length) throw failure('malformed');
    const next = nextCursor(page.nextCursor, request);
    if (request.operation === 'listProjects') return { projects, nextCursor: next,
      coverage: 'Local native Codex project metadata from an independent read-only app-server. Root order is preserved; no primary root or thread working directory is inferred. Listing is not an execution or folder-access grant.' };
    const verifiedMethods = ['project/list'];
    if (projects.length) {
      const response = await server.request('project/read', { projectId: projects[0].identity.externalID });
      const observed = projectSnapshot(response.project, request);
      if (observed.identity.externalID !== projects[0].identity.externalID) throw failure('malformed');
      verifiedMethods.push('project/read');
    }
    return { provider: 'codex', state: 'ready', profileNamespace: request.profileNamespace,
      version: cliVersion, verifiedMethods,
      detail: 'Verified read-only native project listing. ' + (projects.length ? 'Verified project metadata reads. ' : 'Project reads are unverified because the list is empty. ')
        + 'Independent stdio discovery does not connect to desktop activity, continue chats, grant folder access or change projects.' };
  }
  if (request.operation === 'list' || request.operation === 'capabilities') {
    const page = await server.request('thread/list', { limit: request.operation === 'capabilities' ? 1 : 50,
      cursor, archived: request.archived === true, sortKey: 'updated_at', sortDirection: 'desc',
      sourceKinds: ['cli', 'vscode', 'exec', 'appServer', 'subAgent', 'subAgentReview',
                    'subAgentCompact', 'subAgentThreadSpawn', 'subAgentOther', 'unknown'] });
    if (!Array.isArray(page.data) || page.data.length > 50) throw failure('malformed');
    if (request.operation === 'list') return { sessions: page.data.map(t => summary(t, request.archived === true)),
      nextCursor: nextCursor(page.nextCursor, request),
      coverage: 'Local Codex stored sessions exposed by app-server, including archived sessions when selected. Titles use native names only. Remote/cloud sessions and activity in other processes are not established.' };
    return { provider: 'codex', state: 'ready', version: cliVersion,
      detail: 'Verified local read-only session listing. Transcript support is unverified until you explicitly preview a session; setup checks do not read chat contents. ' + TEXT_COVERAGE };
  }
  const metadata = await server.request('thread/read', { threadId: request.id, includeTurns: false });
  const session = summary(metadata.thread);
  if (session.externalID !== request.id) throw failure('malformed');
  const page = await server.request('thread/turns/list', { threadId: request.id, cursor, limit: 10,
    sortDirection: 'asc', itemsView: 'full' });
  if (!Array.isArray(page.data) || page.data.length > 10) throw failure('malformed');
  const next = nextCursor(page.nextCursor, request);
  return { session, messages: messagesFrom(page.data), nextCursor: next, direction: 'newer',
    coverage: TEXT_COVERAGE + (next ? ' Partial transcript: more stored turns remain.' : ' End of currently stored turn history.') };
}

let output;
const deadline = setTimeout(() => {
  for (const p of pending.values()) p.reject(failure('timeout'));
  void stopChild();
}, 16000);
try {
  let input = '';
  for await (const chunk of process.stdin) {
    input += chunk.toString('utf8');
    if (Buffer.byteLength(input) > 32768) throw failure('invalidRequest');
  }
  let request;
  try { request = JSON.parse(input); } catch { throw failure('invalidRequest'); }
  output = JSON.stringify(await execute(request));
  if (Buffer.byteLength(output) > MAX_OUTPUT) throw failure('tooLarge');
} catch (error) {
  const codes = new Set(['invalidRequest', 'unsupported', 'tooLarge', 'timeout', 'malformed']);
  output = JSON.stringify({ error: codes.has(error?.code) ? error.code : 'unavailable' });
  process.exitCode = 1;
} finally {
  clearTimeout(deadline);
  for (const p of pending.values()) clearTimeout(p.timer);
  pending.clear();
  await stopChild();
}
if (!stopSignal) process.stdout.write(output + '\n');
