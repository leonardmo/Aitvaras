// Offline native transport tests: synthetic WebSockets/proxy streams only.
// No Codex daemon, authentication, provider request or production mutation.
import assert from 'node:assert/strict';
import { EventEmitter, once } from 'node:events';
import { PassThrough } from 'node:stream';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { NativeSession, ProxyWebSocket, validateRequest, safeEffectiveConfiguration } from '../Sources/AitvarasConnectors/Resources/codex-native.mjs';

let passed = 0;
const endpoint = 'ws://127.0.0.1:54321/synthetic';
const thread = 'synthetic-thread', turn = 'synthetic-turn';
const effective = { thread: { id: thread, status: { type: 'idle' } }, model: 'synthetic-model', modelProvider: 'synthetic',
  cwd: '/synthetic/workspace', sandbox: { type: 'workspaceWrite', writableRoots: ['/synthetic/workspace'] },
  approvalPolicy: 'on-request', approvalsReviewer: 'user', runtimeWorkspaceRoots: ['/synthetic/workspace'] };
const rejects = (promise, code) => assert.rejects(promise, e => e.code === code);
async function test(name, body) { await body(); passed++; console.log(JSON.stringify({ test: name, passed: true })); }
function fixture(handler, { timeoutMS = 100, open = true } = {}) {
  const sockets = [], events = [];
  class FakeWebSocket extends EventTarget {
    calls = []; closed = false;
    constructor(url) { super(); this.url = url; sockets.push(this); if (open) queueMicrotask(() => this.dispatchEvent(new Event('open'))); }
    send(text) { assert(!this.closed); const frame = JSON.parse(text); this.calls.push(frame); handler(frame, this); }
    message(frame) { this.dispatchEvent(new MessageEvent('message', { data: typeof frame === 'string' ? frame : JSON.stringify(frame) })); }
    reply(frame, result) { queueMicrotask(() => this.message({ id: frame.id, result })); }
    close() { this.closed = true; }
  }
  return { sockets, events, session: new NativeSession({ WebSocketClass: FakeWebSocket, emit: f => events.push(f), timeoutMS }) };
}
function standard(frame, socket) {
  if (frame.method === 'initialize') socket.reply(frame, { userAgent: 'synthetic' });
  else if (frame.method === 'initialized' || !frame.method) return;
  else if (frame.method === 'thread/resume' || frame.method === 'thread/start') socket.reply(frame, structuredClone(effective));
  else if (frame.method === 'thread/read') socket.reply(frame, { thread: effective.thread });
  else if (frame.method === 'turn/start') socket.reply(frame, { turn: { id: turn, status: 'inProgress', items: [] } });
  else socket.reply(frame, { data: [], nextCursor: null });
}
async function connected(handler = standard, options) {
  const f = fixture(handler, options); await f.session.connect({ transport: 'explicitLoopbackWebSocket', endpoint }); return f;
}

function serverFrame(value, { opcode = 1, fin = true } = {}) {
  const payload = Buffer.isBuffer(value) ? value : Buffer.from(value);
  const extra = payload.length < 126 ? 0 : payload.length <= 65535 ? 2 : 8;
  const frame = Buffer.alloc(2 + extra + payload.length); frame[0] = (fin ? 0x80 : 0) | opcode;
  frame[1] = extra === 0 ? payload.length : extra === 2 ? 126 : 127;
  if (extra === 2) frame.writeUInt16BE(payload.length, 2);
  if (extra === 8) frame.writeBigUInt64BE(BigInt(payload.length), 2);
  payload.copy(frame, 2 + extra); return frame;
}
function clientFrame(frame) {
  assert(frame[1] & 0x80); const marker = frame[1] & 0x7f;
  const size = marker < 126 ? marker : marker === 126 ? frame.readUInt16BE(2) : Number(frame.readBigUInt64BE(2));
  const offset = marker < 126 ? 2 : marker === 126 ? 4 : 10;
  const mask = frame.subarray(offset, offset + 4), payload = Buffer.alloc(size);
  for (let i = 0; i < size; i++) payload[i] = frame[offset + 4 + i] ^ mask[i % 4];
  return { opcode: frame[0] & 0xf, fin: !!(frame[0] & 0x80), payload };
}
function upgradeFor(request) {
  const key = /Sec-WebSocket-Key: ([^\r]+)/.exec(request.toString('ascii'))[1];
  const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  return Buffer.from(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
}
function byteFixture() {
  const writes = [], texts = [], errors = []; let opened = 0;
  const input = { destroyed: false, writableLength: 0, write(bytes) { writes.push(Buffer.from(bytes)); } };
  const socket = new ProxyWebSocket({ input, onOpen: () => opened++, onText: text => texts.push(text), onFailure: code => errors.push(code) });
  socket.start();
  return { socket, writes, texts, errors, input, get opened() { return opened; }, upgrade() { socket.receive(upgradeFor(writes[0])); } };
}

await test('byte proxy performs verified HTTP upgrade and masks every client frame size', async () => {
  const f = byteFixture(), header = upgradeFor(f.writes[0]);
  assert(f.writes[0].toString().startsWith('GET /rpc HTTP/1.1\r\nHost: localhost\r\n'));
  f.socket.receive(header.subarray(0, 13)); assert.equal(f.opened, 0);
  f.socket.receive(Buffer.concat([header.subarray(13), serverFrame('synthetic-first')]));
  assert.equal(f.opened, 1); assert.deepEqual(f.texts, ['synthetic-first']);
  for (const count of [0, 125, 126, 65535, 65536]) {
    const text = 'x'.repeat(count); f.socket.sendText(text);
    const decoded = clientFrame(f.writes.at(-1));
    assert.equal(decoded.opcode, 1); assert(decoded.fin); assert.equal(decoded.payload.toString(), text);
  }
  assert.deepEqual(f.errors, []);
});

await test('byte proxy requires exact accept hash, status and upgrade headers', async () => {
  for (const transform of [
    h => h.replace('101 Switching Protocols', '302 Redirect'),
    h => h.replace(/Sec-WebSocket-Accept: [^\r]+/, 'Sec-WebSocket-Accept: synthetic-wrong'),
    h => h.replace('Upgrade: websocket', 'Upgrade: other'),
    h => h.replace('Connection: keep-alive, Upgrade', 'Connection: close'),
    h => h.replace('\r\n\r\n', '\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n'),
    h => h.replace('\r\n\r\n', '\r\nSec-WebSocket-Protocol: unrequested\r\n\r\n'),
    h => h.replace('\r\n\r\n', '\r\nUpgrade: websocket\r\n\r\n')
  ]) {
    const f = byteFixture(); f.socket.receive(Buffer.from(transform(upgradeFor(f.writes[0]).toString())));
    assert.equal(f.opened, 0); assert.equal(f.errors.length, 1);
  }
  const large = byteFixture(); large.socket.receive(Buffer.alloc(16385, 65)); assert.deepEqual(large.errors, ['tooLarge']);
});

await test('byte proxy supports fragmented UTF-8 and interleaved ping/pong', async () => {
  const f = byteFixture(); f.upgrade();
  const text = Buffer.from('synthetic-ä-🙂');
  const frames = Buffer.concat([serverFrame(text.subarray(0, text.length - 2), { fin: false }),
    serverFrame('synthetic-ping', { opcode: 9 }), serverFrame(text.subarray(text.length - 2), { opcode: 0 }),
    serverFrame('synthetic-pong', { opcode: 10 })]);
  for (let i = 0; i < frames.length; i += 3) f.socket.receive(frames.subarray(i, i + 3));
  assert.deepEqual(f.texts, [text.toString()]); assert.deepEqual(f.errors, []);
  const pong = clientFrame(f.writes.at(-1)); assert.equal(pong.opcode, 10); assert.equal(pong.payload.toString(), 'synthetic-ping');
});

await test('byte proxy rejects malformed frames, invalid UTF-8 and oversized fragments', async () => {
  const malformed = [Buffer.from([0xc1, 0]), Buffer.from([0x81, 0x80, 0, 0, 0, 0]),
    serverFrame('binary', { opcode: 2 }), serverFrame('orphan', { opcode: 0 }),
    Buffer.from([0x81, 126, 0, 1, 65]), Buffer.from([0x81, 127, 0, 0, 0, 0, 0, 0, 0, 1, 65]),
    serverFrame(Buffer.from([0xc0, 0xaf])), serverFrame('fragmented-control', { opcode: 9, fin: false }),
    serverFrame(Buffer.from([1]), { opcode: 8 }), serverFrame(Buffer.from([0x03, 0xed]), { opcode: 8 }),
    Buffer.concat([serverFrame('a', { fin: false }), serverFrame('b')])];
  for (const bytes of malformed) {
    const f = byteFixture(); f.upgrade(); f.socket.receive(bytes);
    assert.equal(f.errors.length, 1); assert.equal(f.texts.length, 0);
  }
  const huge = byteFixture(); huge.upgrade(); huge.socket.receive(Buffer.from([0x81, 127, 0, 0, 0, 0, 1, 0, 0, 0]));
  assert.deepEqual(huge.errors, ['tooLarge']);
  const fragments = byteFixture(); fragments.upgrade();
  fragments.socket.receive(serverFrame(Buffer.alloc(3 * 1024 * 1024, 65), { fin: false }));
  fragments.socket.receive(serverFrame(Buffer.alloc(2 * 1024 * 1024, 65), { opcode: 0 }));
  assert.deepEqual(fragments.errors, ['tooLarge']);
});

await test('byte proxy acknowledges native close once without approving actions', async () => {
  const f = byteFixture(); f.upgrade(); const close = Buffer.from([0x03, 0xe8]);
  f.socket.receive(serverFrame(close, { opcode: 8 }));
  assert.deepEqual(f.errors, ['disconnected']);
  assert.equal(clientFrame(f.writes.at(-1)).opcode, 8);
  assert.deepEqual(clientFrame(f.writes.at(-1)).payload, close);
  const count = f.writes.length; f.socket.close(); assert.equal(f.writes.length, count);
});

await test('handshake is persistent and makes no identity claim', async () => {
  const f = fixture(standard);
  const info = await f.session.connect({ transport: 'explicitLoopbackWebSocket', endpoint });
  assert.equal(info.runtimeIdentityKnown, false); assert.equal(info.desktopAttachmentVerified, false);
  assert.deepEqual(f.sockets[0].calls.map(x => x.method), ['initialize', 'initialized']);
  await f.session.request('project/list', { limit: 1 });
  await f.session.request('thread/read', { threadId: thread, includeTurns: false });
  assert(!f.sockets[0].closed); f.session.abort(); assert(f.sockets[0].closed);
});

await test('only existing default proxy is launched with minimal environment', async () => {
  let invocation, child;
  const session = new NativeSession({ timeoutMS: 100, spawnProxy(executable, args, options) {
    invocation = { executable, args, options }; child = new EventEmitter();
    child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.pid = 54321; child.exitCode = null; child.signalCode = null;
    child.kill = signal => { child.signalCode = signal; queueMicrotask(() => child.emit('exit', null, signal)); };
    let upgraded = false;
    child.stdin.on('data', data => {
      if (!upgraded) { upgraded = true; queueMicrotask(() => child.stdout.write(upgradeFor(data))); return; }
      const decoded = clientFrame(data); if (decoded.opcode !== 1) return;
      const frame = JSON.parse(decoded.payload.toString());
      if (frame.method === 'initialize') queueMicrotask(() => child.stdout.write(serverFrame(JSON.stringify({ id: frame.id, result: {} }))));
    });
    queueMicrotask(() => child.emit('spawn')); return child;
  } });
  await session.connect({ transport: 'defaultProxy', executable: '/synthetic/codex', home: '/synthetic/profile' });
  assert.deepEqual(invocation.args, ['app-server', 'proxy']); assert.equal(invocation.options.detached, true);
  assert.deepEqual(Object.keys(invocation.options.env).sort(), ['CODEX_HOME', 'HOME', 'LANG', 'NO_COLOR', 'PATH']);
  assert.equal(invocation.options.env.CODEX_HOME, '/synthetic/profile');
  assert(!invocation.args.includes('--listen')); session.abort();
});

await test('unavailable proxy never falls back to independent app-server', async () => {
  let spawns = 0;
  const session = new NativeSession({ timeoutMS: 100, spawnProxy() {
    spawns++; const child = new EventEmitter(); child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.kill = () => {};
    queueMicrotask(() => child.emit('error', new Error('synthetic failure'))); return child;
  } });
  await rejects(session.connect({ transport: 'defaultProxy', executable: '/synthetic/codex', home: '/synthetic/profile' }), 'unavailable');
  assert.equal(spawns, 1);
});

await test('method and parameter allowlist prevents indirect shell or config changes', async () => {
  const f = await connected();
  for (const method of ['thread/shellCommand', 'thread/delete', 'project/delete', 'thread/revert', 'thread/injectItems',
    'turn/steer', 'process/spawn', 'command/exec', 'config/value/write', 'account/login/start', 'thread/fork']) {
    await rejects(f.session.request(method, {}), 'invalidRequest');
  }
  for (const [method, params] of [
    ['thread/resume', { threadId: thread, config: { approval_policy: 'never' } }],
    ['thread/resume', { threadId: thread, path: '/synthetic/rollout' }],
    ['thread/start', { cwd: '/synthetic/workspace', dynamicTools: [] }],
    ['turn/start', { threadId: thread, input: [], sandboxPolicy: { type: 'dangerFullAccess' } }],
    ['account/read', { refreshToken: true }], ['project/update', { projectId: '../synthetic' }],
    ['project/create', { name: 'Synthetic', idempotencyKey: 'synthetic-id', roots: [{ path: 'relative' }] }]
  ]) await rejects(f.session.request(method, params), 'invalidRequest');
  assert.equal(f.sockets[0].calls.length, 2); f.session.abort();
});

await test('resume preserves all native tools and permissions without overrides', async () => {
  const f = await connected();
  const result = await f.session.request('thread/resume', { threadId: thread });
  assert.deepEqual(result, effective);
  assert.deepEqual(f.sockets[0].calls.at(-1).params, { threadId: thread });
  f.session.abort();
});

await test('new native thread keeps its effective config without an empty-rollout resume', async () => {
  const f = await connected();
  const created = await f.session.request('thread/start', { projectId: 'synthetic-project', cwd: '/synthetic/workspace' });
  assert.deepEqual(created, effective);
  await f.session.request('turn/start', { threadId: thread, input: [{ type: 'text', text: 'Synthetic first input' }] });
  assert(!f.sockets[0].calls.some(x => x.method === 'thread/resume'));
  f.session.abort();
});

await test('send checks effective permissions and fresh native idle state', async () => {
  const f = await connected();
  const params = { threadId: thread, input: [{ type: 'text', text: 'Synthetic input', text_elements: [] }], model: 'synthetic-model' };
  await rejects(f.session.request('turn/start', params), 'unreviewedConfiguration');
  await f.session.request('thread/resume', { threadId: thread });
  await f.session.request('turn/start', params);
  assert.deepEqual(f.sockets[0].calls.slice(-2).map(x => x.method), ['thread/read', 'turn/start']);
  assert.deepEqual(f.sockets[0].calls.at(-1).params, params);
  f.session.abort();
  for (const type of ['dangerFullAccess', 'externalSandbox', 'unknown']) assert(!safeEffectiveConfiguration({ ...effective, sandbox: { type } }));
  assert(!safeEffectiveConfiguration({ ...effective, approvalsReviewer: 'auto_review' }));
  assert(!safeEffectiveConfiguration({ ...effective, approvalPolicy: 'unknown-policy' }));
  assert(safeEffectiveConfiguration({ ...effective, approvalPolicy: 'never' }));
});

await test('busy native thread and concurrent local start cannot steer intentionally', async () => {
  const f = await connected((frame, socket) => frame.method === 'thread/read' ? socket.reply(frame, { thread: { id: thread, status: { type: 'active' } } }) : standard(frame, socket));
  await f.session.request('thread/resume', { threadId: thread });
  const params = { threadId: thread, input: [{ type: 'text', text: 'Synthetic' }] };
  await rejects(f.session.request('turn/start', params), 'busy');
  assert(!f.sockets[0].calls.some(x => x.method === 'turn/start')); f.session.abort();
  const g = await connected((frame, socket) => frame.method === 'thread/read' ? undefined : standard(frame, socket));
  await g.session.request('thread/resume', { threadId: thread });
  const first = g.session.request('turn/start', params);
  await rejects(g.session.request('turn/start', params), 'busy');
  g.session.abort(); await rejects(first, 'disconnected');
});

await test('server actions require an explicit exact scoped user response', async () => {
  const f = await connected(); await f.session.request('thread/resume', { threadId: thread });
  const s = f.sockets[0], before = s.calls.length;
  s.message({ id: 'synthetic-approval', method: 'item/commandExecution/requestApproval', params: {
    threadId: thread, turnId: turn, itemId: 'synthetic-item', command: 'synthetic-command', availableDecisions: ['accept', 'decline', 'cancel']
  } });
  assert.equal(s.calls.length, before); assert.equal(f.events.at(-1).kind, 'serverRequest');
  for (const changes of [{ threadID: 'other-thread' }, { turnID: 'other-turn' }, { requestID: 'other-request' }]) {
    assert.throws(() => f.session.respond({ requestID: 'synthetic-approval', threadID: thread, turnID: turn, result: { decision: 'accept' }, ...changes }), e => e.code === 'approvalScope');
  }
  assert.throws(() => f.session.respond({ requestID: 'synthetic-approval', threadID: thread, turnID: turn, result: { decision: 'acceptForSession' } }), e => e.code === 'invalidRequest');
  f.session.respond({ requestID: 'synthetic-approval', threadID: thread, turnID: turn, result: { decision: 'accept' } });
  assert.deepEqual(s.calls.at(-1), { id: 'synthetic-approval', result: { decision: 'accept' } });
  assert.throws(() => f.session.respond({ requestID: 'synthetic-approval', threadID: thread, turnID: turn, result: { decision: 'accept' } }), e => e.code === 'approvalScope');
  f.session.abort();
});

await test('unknown/unscoped requests receive no approval, authentication or execution', async () => {
  const f = await connected(); const s = f.sockets[0];
  for (const method of ['item/tool/call', 'account/chatgptAuthTokens/refresh', 'attestation/generate', 'unknown']) {
    s.message({ id: `synthetic-${method}`, method, params: { threadId: thread, turnId: turn } });
    assert.equal(s.calls.at(-1).error.code, -32601); assert(!Object.hasOwn(s.calls.at(-1), 'result'));
  }
  s.message({ id: 90, method: 'item/commandExecution/requestApproval', params: { threadId: thread, turnId: turn } });
  assert.equal(s.calls.at(-1).error.code, -32601); f.session.abort();
});

await test('resolved and expired-scope approvals cannot be replayed', async () => {
  const f = await connected(); await f.session.request('thread/resume', { threadId: thread });
  const s = f.sockets[0];
  s.message({ id: 31, method: 'item/fileChange/requestApproval', params: { threadId: thread, turnId: turn, itemId: 'synthetic-item' } });
  s.message({ method: 'serverRequest/resolved', params: { threadId: thread, requestId: 31 } });
  assert.throws(() => f.session.respond({ requestID: 31, threadID: thread, turnID: turn, result: { decision: 'accept' } }), e => e.code === 'approvalScope');
  f.session.abort();
});

await test('permissions cannot become persistent or exceed the exact requested grant', async () => {
  const f = await connected(); await f.session.request('thread/resume', { threadId: thread });
  const permissions = { network: { enabled: true } };
  f.sockets[0].message({ id: 32, method: 'item/permissions/requestApproval', params: { threadId: thread, turnId: turn, permissions } });
  const base = { requestID: 32, threadID: thread, turnID: turn };
  assert.throws(() => f.session.respond({ ...base, result: { permissions, scope: 'session' } }), e => e.code === 'invalidRequest');
  assert.throws(() => f.session.respond({ ...base, result: { permissions: { network: { enabled: true }, fileSystem: {} } } }), e => e.code === 'invalidRequest');
  f.session.respond({ ...base, result: { permissions: {}, scope: 'turn' } }); f.session.abort();
});

await test('native notifications preserve arbitrary nontext item payloads', async () => {
  const f = await connected();
  const params = { threadId: thread, turnId: turn, item: { id: 'synthetic-item', type: 'futureItem', arbitrary: { data: [1, true, null, 'opaque'] } } };
  f.sockets[0].message({ method: 'item/completed', params });
  assert.deepEqual(f.events.at(-1), { kind: 'notification', method: 'item/completed', params }); f.session.abort();
});

await test('timeout closes client and never automatically resends uncertain input', async () => {
  const f = await connected((frame, socket) => frame.method === 'turn/start' ? undefined : standard(frame, socket));
  await f.session.request('thread/resume', { threadId: thread });
  await rejects(f.session.request('turn/start', { threadId: thread, input: [{ type: 'text', text: 'Synthetic' }] }), 'timeout');
  assert.equal(f.sockets[0].calls.filter(x => x.method === 'turn/start').length, 1); assert(f.sockets[0].closed);
});

await test('malformed, oversized, duplicate and uncorrelated responses fail closed', async () => {
  for (const payload of ['not-json', '[]', { id: 999, result: {} }, { id: 1, result: {}, error: {} }, { id: 1 }, 'x'.repeat(4 * 1024 * 1024 + 1)]) {
    const f = fixture((frame, socket) => { if (frame.method === 'initialize') queueMicrotask(() => socket.message(payload)); });
    await assert.rejects(f.session.connect({ transport: 'explicitLoopbackWebSocket', endpoint }), e => ['malformed', 'tooLarge'].includes(e.code));
    assert(f.sockets[0].closed);
  }
});

await test('native websocket refuses redirect without contacting its target', async () => {
  let targetRequests = 0;
  const target = createServer((q, r) => { targetRequests++; r.end(); }); target.on('upgrade', (q, s) => { targetRequests++; s.destroy(); });
  target.listen(0, '127.0.0.1'); await once(target, 'listening');
  const redirect = createServer((q, r) => { r.writeHead(302, { Location: `ws://127.0.0.1:${target.address().port}` }); r.end(); });
  redirect.on('upgrade', (q, s) => s.end(`HTTP/1.1 302 Found\r\nLocation: ws://127.0.0.1:${target.address().port}\r\nContent-Length: 0\r\n\r\n`));
  redirect.listen(0, '127.0.0.1'); await once(redirect, 'listening');
  try {
    const session = new NativeSession({ timeoutMS: 500 });
    await rejects(session.connect({ transport: 'explicitLoopbackWebSocket', endpoint: `ws://127.0.0.1:${redirect.address().port}` }), 'unavailable');
    assert.equal(targetRequests, 0);
  } finally { await Promise.all([new Promise(r => redirect.close(r)), new Promise(r => target.close(r))]); }
});

console.log(JSON.stringify({ passed, liveProviderRequests: 0, nativeCodexProcesses: 0, productionProfileChanges: 0 }));
