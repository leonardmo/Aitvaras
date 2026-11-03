// Offline transport contract tests: fake WebSockets and tiny local HTTP fixtures,
// never a native Codex process, production profile, credentials or model provider.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { SharedRuntimeProbe, validateEndpoint } from '../Sources/AitvarasConnectors/Resources/codex-shared-runtime.mjs';

let passed = 0;
async function test(name, body) { await body(); passed++; console.log(JSON.stringify({ test: name, passed: true })); }
const endpoint = 'ws://127.0.0.1:54321/synthetic';
const helper = fileURLToPath(new URL('../Sources/AitvarasConnectors/Resources/codex-shared-runtime.mjs', import.meta.url));

function fixture(handler, { open = true } = {}) {
  const sockets = [];
  class FakeWebSocket extends EventTarget {
    calls = []; closed = false;
    constructor(url) { super(); this.url = url; sockets.push(this); if (open) queueMicrotask(() => this.dispatchEvent(new Event('open'))); }
    send(text) {
      assert(!this.closed);
      const frame = JSON.parse(text); this.calls.push(frame);
      handler?.(frame, this);
    }
    message(data) { this.dispatchEvent(new MessageEvent('message', { data: typeof data === 'string' ? data : JSON.stringify(data) })); }
    reply(frame, result) { queueMicrotask(() => this.message({ id: frame.id, result })); }
    close() { this.closed = true; }
  }
  return { sockets, probe: new SharedRuntimeProbe({ WebSocketClass: FakeWebSocket, timeoutMS: 100 }) };
}
function standard(frame, socket) {
  if (frame.method === 'initialize') socket.reply(frame, { userAgent: 'synthetic-server' });
  else if (frame.method === 'project/list') socket.reply(frame, { data: [{ id: 'synthetic-project', roots: ['/synthetic/private-root'] }], nextCursor: null });
  else assert.equal(frame.method, 'initialized');
}
const rejects = (promise, code) => assert.rejects(promise, error => error.code === code);

await test('strict explicit loopback authority', async () => {
  for (const value of [endpoint, 'ws://[::1]:54321/', 'ws://127.0.0.1:80', 'ws://[::1]:65535/probe']) assert(validateEndpoint(value));
  for (const value of ['', 'ws://localhost:54321', 'ws://127.1:54321', 'ws://2130706433:54321',
    'ws://0x7f000001:54321', 'ws://127.0.0.2:54321', 'ws://[::ffff:127.0.0.1]:54321',
    'ws://192.0.2.1:54321', 'wss://127.0.0.1:54321', 'http://127.0.0.1:54321',
    'ws://user:secret@127.0.0.1:54321', 'ws://127.0.0.1:54321?token=synthetic',
    'ws://127.0.0.1:54321#synthetic', 'ws://127.0.0.1:54321?', 'ws://127.0.0.1:54321#',
    'ws://127.0.0.1', 'ws://127.0.0.1:0', 'ws://127.0.0.1:65536', 'ws://127.0.0.1:05432',
    'ws://127.0.0.1:54321/%2f', 'ws://127.0.0.1:54321/\\synthetic', 'ws://127.0.0.1:54321/\n',
    'ws://127.0.0.1:54321/é']) assert.throws(() => validateEndpoint(value), error => error.code === 'invalidEndpoint');
});

await test('exact read-only handshake and no inferred identity', async () => {
  const { probe, sockets } = fixture(standard);
  const result = await probe.probe(endpoint);
  assert.deepEqual(sockets[0].calls.map(frame => frame.method), ['initialize', 'initialized', 'project/list']);
  assert.deepEqual(sockets[0].calls[2].params, { limit: 1, cursor: null });
  assert.deepEqual(result, { connected: true, transport: 'explicitLoopbackWebSocket', projectListAvailable: true,
    runtimeIdentity: 'unknown', desktopAttachmentVerified: false, continuationSupported: false });
  assert(!JSON.stringify(result).includes('/synthetic/private-root'));
  assert(!JSON.stringify(result).includes('synthetic-project'));
  assert(sockets[0].closed);
});

await test('invalid endpoint never constructs a socket', async () => {
  const { probe, sockets } = fixture(standard);
  await rejects(probe.probe('ws://localhost:54321'), 'invalidEndpoint');
  assert.equal(sockets.length, 0);
});

await test('mutating/auth/model/thread methods are denied at dispatch', async () => {
  const { probe, sockets } = fixture(standard);
  for (const method of ['turn/start', 'thread/resume', 'thread/start', 'model/list', 'account/read', 'account/login/start',
    'project/update', 'project/create', 'project/delete', 'config/read', 'initialized']) await rejects(probe.rpc(method, {}), 'forbiddenMethod');
  assert.equal(sockets.length, 0);
});

await test('missing project method fails capability check', async () => {
  const { probe } = fixture((frame, socket) => {
    if (frame.method === 'project/list') queueMicrotask(() => socket.message({ id: frame.id, error: { code: -32601, message: 'SYNTHETIC_PRIVATE_ERROR' } }));
    else standard(frame, socket);
  });
  await rejects(probe.probe(endpoint), 'unsupported');
});

await test('server action requests never receive approval', async () => {
  const { probe, sockets } = fixture((frame, socket) => {
    if (frame.method === 'initialize') queueMicrotask(() => socket.message({ id: 'synthetic-request', method: 'item/commandExecution/requestApproval' }));
  });
  await rejects(probe.probe(endpoint), 'serverRequest');
  assert.equal(sockets[0].calls.length, 1);
});

await test('malformed and uncorrelated protocol fails closed', async () => {
  for (const message of ['not-json', '[]', { id: 999, result: {} }, { id: 1, result: {}, error: {} },
    { id: 1 }, { method: 1 }, { id: 1, method: 'synthetic' }]) {
    const { probe } = fixture((frame, socket) => { if (frame.method === 'initialize') queueMicrotask(() => socket.message(message)); });
    await assert.rejects(probe.probe(endpoint), error => ['malformed', 'serverRequest'].includes(error.code));
  }
});

await test('project list must have reviewed bounded response shape', async () => {
  for (const result of [{}, { data: [] }, { data: {}, nextCursor: null }, { data: [null], nextCursor: null },
    { data: [{}, {}], nextCursor: null }, { data: [], nextCursor: 1 }]) {
    const { probe } = fixture((frame, socket) => frame.method === 'project/list' ? socket.reply(frame, result) : standard(frame, socket));
    await rejects(probe.probe(endpoint), 'malformed');
  }
});

await test('frame, total wire and notification count are bounded', async () => {
  for (const flood of [socket => socket.message('x'.repeat(512 * 1024 + 1)),
    socket => { for (let n = 0; n < 3; n++) socket.message({ method: 'synthetic', params: 'x'.repeat(400 * 1024) }); },
    socket => { for (let n = 0; n < 257; n++) socket.message({ method: 'synthetic' }); }]) {
    const { probe } = fixture((frame, socket) => { if (frame.method === 'initialize') queueMicrotask(() => flood(socket)); });
    await rejects(probe.probe(endpoint), 'tooLarge');
  }
});

await test('bounded open/request timeout and cancellation close socket', async () => {
  for (const open of [true, false]) {
    const { probe, sockets } = fixture(() => {}, { open });
    await rejects(probe.probe(endpoint), 'timeout'); assert(sockets[0].closed);
  }
  const controller = new AbortController();
  const { probe, sockets } = fixture(() => {});
  const operation = probe.probe(endpoint, { signal: controller.signal });
  controller.abort(); await rejects(operation, 'cancelled'); assert(sockets[0].closed);
  const aborted = new AbortController(); aborted.abort();
  const before = fixture(standard);
  await rejects(before.probe.probe(endpoint, { signal: aborted.signal }), 'cancelled');
  assert.equal(before.sockets.length, 0);
});

await test('native WebSocket refuses redirects without following another listener', async () => {
  let redirectedRequests = 0;
  const target = createServer((request, response) => { redirectedRequests++; response.end(); });
  target.on('upgrade', (request, socket) => { redirectedRequests++; socket.destroy(); });
  target.listen(0, '127.0.0.1'); await once(target, 'listening');
  const redirect = createServer((request, response) => { response.writeHead(302, { Location: `ws://127.0.0.1:${target.address().port}/synthetic` }); response.end(); });
  redirect.on('upgrade', (request, socket) => socket.end(`HTTP/1.1 302 Found\r\nLocation: ws://127.0.0.1:${target.address().port}/synthetic\r\nContent-Length: 0\r\n\r\n`));
  redirect.listen(0, '127.0.0.1'); await once(redirect, 'listening');
  try {
    await rejects(new SharedRuntimeProbe({ timeoutMS: 500 }).probe(`ws://127.0.0.1:${redirect.address().port}/synthetic`), 'unavailable');
    assert.equal(redirectedRequests, 0);
  } finally { await Promise.all([new Promise(resolve => redirect.close(resolve)), new Promise(resolve => target.close(resolve))]); }
});

await test('helper rejects arbitrary input without exposing diagnostics', async () => {
  for (const request of [{ operation: 'probe', endpoint: 'ws://localhost:54321' },
    { operation: 'turn/start', endpoint }, { operation: 'probe', endpoint, executable: '/synthetic/codex' }]) {
    const child = spawn(process.execPath, [helper], { env: { PATH: '/usr/bin:/bin' }, stdio: ['pipe', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', data => { stdout += data; }); child.stderr.on('data', data => { stderr += data; });
    child.stdin.end(JSON.stringify(request));
    const [code] = await once(child, 'exit');
    assert.equal(code, 1); assert.equal(stderr, '');
    assert(['invalidEndpoint', 'invalidRequest'].includes(JSON.parse(stdout).error));
    assert(!stdout.includes(endpoint));
  }
});

console.log(JSON.stringify({ passed, liveProviderRequests: 0, nativeCodexProcesses: 0, productionProfileChanges: 0 }));
