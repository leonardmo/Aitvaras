// A persistent client of an EXISTING native runtime. The proxy command only
// attaches to its default control socket; this helper never launches app-server.
import { spawn } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { validateEndpoint } from './codex-shared-runtime.mjs';

const MAX_FRAME = 4 * 1024 * 1024, MAX_WIRE = 64 * 1024 * 1024, MAX_PENDING = 64;
const fail = code => Object.assign(new Error(code), { code });
const object = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const own = (v, k) => Object.hasOwn(v, k);
const validID = v => typeof v === 'string' && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(v);
const methods = {
  'project/list': ['cursor', 'limit'], 'project/read': ['projectId'],
  'project/create': ['name', 'roots', 'metadata', 'idempotencyKey'],
  'project/update': ['projectId', 'name', 'roots', 'metadata'],
  'thread/list': ['cursor', 'limit', 'archived', 'projectId', 'cwd', 'sortKey', 'sortDirection', 'searchTerm', 'sourceKinds', 'modelProviders'],
  'thread/read': ['threadId', 'includeTurns'],
  'thread/turns/list': ['threadId', 'cursor', 'limit', 'sortDirection', 'itemsView'],
  'thread/items/list': ['threadId', 'turnId', 'cursor', 'limit', 'sortDirection'],
  'thread/resume': ['threadId'],
  'thread/start': ['cwd', 'projectId', 'model', 'modelProvider'],
  'thread/metadata/update': ['threadId', 'projectId'], 'thread/name/set': ['threadId', 'name'],
  'thread/archive': ['threadId'], 'thread/unarchive': ['threadId'],
  'thread/unsubscribe': ['threadId'], 'model/list': ['cursor', 'limit', 'includeHidden'],
  'account/read': ['refreshToken'], 'account/rateLimits/read': [],
  'config/read': ['cwd', 'includeLayers'],
  'turn/start': ['threadId', 'input', 'model', 'effort', 'clientUserMessageId'],
  'turn/interrupt': ['threadId', 'turnId']
};
const serverMethods = new Set(['item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
  'item/permissions/requestApproval', 'item/tool/requestUserInput', 'mcpServer/elicitation/request']);

const websocketGUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

/// RFC 6455 over the official CLI's raw-byte control-socket proxy. The proxy
/// does not translate JSONL to WebSocket: this client owns the HTTP upgrade and
/// masking/framing, without learning or guessing the native socket pathname.
export class ProxyWebSocket {
  constructor({ input, onOpen, onText, onFailure }) {
    this.input = input; this.onOpen = onOpen; this.onText = onText; this.onFailure = onFailure;
    this.buffer = Buffer.alloc(0); this.fragments = []; this.fragmentBytes = 0;
    this.key = randomBytes(16).toString('base64'); this.bytes = 0; this.frames = 0;
  }
  start() {
    if (this.started || this.failed) throw fail('invalidRequest');
    this.started = true;
    this.write(Buffer.from('GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n' +
      `Sec-WebSocket-Key: ${this.key}\r\nSec-WebSocket-Version: 13\r\n\r\n`, 'ascii'));
  }
  write(bytes) {
    if (this.failed || this.input.destroyed || this.input.writableLength + bytes.length > MAX_FRAME + 16384) throw fail('tooLarge');
    this.input.write(bytes);
  }
  sendFrame(opcode, payload = Buffer.alloc(0)) {
    if (!this.upgraded || this.failed || (this.sentClose && opcode !== 8)) throw fail('disconnected');
    if (payload.length > MAX_FRAME || (opcode >= 8 && payload.length > 125)) throw fail('tooLarge');
    const extra = payload.length < 126 ? 0 : payload.length <= 65535 ? 2 : 8;
    const bytes = Buffer.allocUnsafe(2 + extra + 4 + payload.length);
    bytes[0] = 0x80 | opcode;
    bytes[1] = 0x80 | (extra === 0 ? payload.length : extra === 2 ? 126 : 127);
    if (extra === 2) bytes.writeUInt16BE(payload.length, 2);
    else if (extra === 8) bytes.writeBigUInt64BE(BigInt(payload.length), 2);
    const mask = randomBytes(4), maskOffset = 2 + extra;
    mask.copy(bytes, maskOffset);
    for (let i = 0; i < payload.length; i++) bytes[maskOffset + 4 + i] = payload[i] ^ mask[i % 4];
    this.write(bytes);
  }
  sendText(text) { this.sendFrame(1, Buffer.from(text, 'utf8')); }
  close() {
    if (this.upgraded && !this.failed && !this.sentClose) {
      try { this.sendFrame(8, Buffer.from([0x03, 0xe8])); } catch {}
      this.sentClose = true;
    }
  }
  abort(code = 'malformed') {
    if (this.failed) return;
    this.failed = true; this.buffer = Buffer.alloc(0); this.fragments = []; this.fragmentBytes = 0;
    this.onFailure(code);
  }
  receive(chunk) {
    if (this.failed) return;
    try {
      if (!Buffer.isBuffer(chunk)) throw fail('malformed');
      this.bytes += chunk.length;
      if (this.bytes > MAX_WIRE) throw fail('tooLarge');
      this.buffer = Buffer.concat([this.buffer, chunk]);
      if (!this.upgraded) {
        const end = this.buffer.indexOf('\r\n\r\n');
        if (end < 0) { if (this.buffer.length > 16384) throw fail('tooLarge'); return; }
        if (end + 4 > 16384) throw fail('tooLarge');
        const headerBytes = this.buffer.subarray(0, end);
        if (headerBytes.some(v => (v < 32 && v !== 13 && v !== 10 && v !== 9) || v > 126)) throw fail('malformed');
        const lines = headerBytes.toString('ascii').split('\r\n');
        if (!/^HTTP\/1\.1 101(?: [\x20-\x7e]*)?$/.test(lines.shift())) throw fail('unavailable');
        const headers = new Map();
        for (const line of lines) {
          const match = /^([!#$%&'*+.^_`|~0-9A-Za-z-]+):[ \t]*([^\r\n]*)$/.exec(line);
          if (!match) throw fail('malformed');
          const name = match[1].toLowerCase();
          if (headers.has(name)) throw fail('malformed');
          headers.set(name, match[2].trim());
        }
        const accept = createHash('sha1').update(this.key + websocketGUID).digest('base64');
        if (headers.get('sec-websocket-accept') !== accept || headers.get('upgrade')?.toLowerCase() !== 'websocket' ||
            !headers.get('connection')?.toLowerCase().split(',').map(v => v.trim()).includes('upgrade') ||
            headers.has('sec-websocket-extensions') || headers.has('sec-websocket-protocol')) throw fail('malformed');
        this.buffer = this.buffer.subarray(end + 4); this.upgraded = true; this.onOpen();
      }
      while (!this.failed && this.buffer.length >= 2) {
        const first = this.buffer[0], second = this.buffer[1], fin = (first & 0x80) !== 0, opcode = first & 0x0f;
        if ((first & 0x70) || (second & 0x80) || ![0, 1, 8, 9, 10].includes(opcode)) throw fail('malformed');
        const marker = second & 0x7f;
        let size = marker, offset = 2;
        if (marker === 126) {
          if (this.buffer.length < 4) return;
          size = this.buffer.readUInt16BE(2); offset = 4;
          if (size < 126) throw fail('malformed');
        } else if (marker === 127) {
          if (this.buffer.length < 10) return;
          const length = this.buffer.readBigUInt64BE(2);
          if (length > BigInt(MAX_FRAME)) throw fail('tooLarge');
          size = Number(length); offset = 10;
          if (size <= 65535) throw fail('malformed');
        }
        if (size > MAX_FRAME || (opcode >= 8 && (!fin || size > 125))) throw fail('tooLarge');
        if (this.buffer.length < offset + size) return;
        const payload = this.buffer.subarray(offset, offset + size);
        this.buffer = this.buffer.subarray(offset + size);
        if (++this.frames > 100000) throw fail('tooLarge');
        if (opcode === 9) { this.sendFrame(10, payload); continue; }
        if (opcode === 10) continue;
        if (opcode === 8) {
          if (payload.length === 1) throw fail('malformed');
          if (payload.length >= 2) {
            const code = payload.readUInt16BE();
            if (!(code >= 3000 && code <= 4999) && ![1000, 1001, 1002, 1003, 1007, 1008, 1009, 1010, 1011, 1012, 1013, 1014].includes(code)) throw fail('malformed');
            new TextDecoder('utf-8', { fatal: true }).decode(payload.subarray(2));
          }
          if (!this.sentClose) { this.sendFrame(8, payload); this.sentClose = true; }
          this.abort('disconnected'); return;
        }
        if ((opcode === 0 && !this.fragmented) || (opcode === 1 && this.fragmented)) throw fail('malformed');
        this.fragmentBytes += payload.length;
        if (this.fragmentBytes > MAX_FRAME || this.fragments.length >= 16384) throw fail('tooLarge');
        this.fragments.push(Buffer.from(payload)); this.fragmented = !fin;
        if (fin) {
          const text = new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(this.fragments, this.fragmentBytes));
          this.fragments = []; this.fragmentBytes = 0; this.fragmented = false;
          this.onText(text);
        }
      }
      if (this.buffer.length > MAX_FRAME + 14) throw fail('tooLarge');
    } catch (error) { this.abort(error.code === 'tooLarge' || error.code === 'unavailable' ? error.code : 'malformed'); }
  }
}

export function validateRequest(method, params) {
  const keys = methods[method];
  if (!keys || !object(params) || Object.keys(params).some(k => !keys.includes(k))) throw fail('invalidRequest');
  if (Buffer.byteLength(JSON.stringify(params)) > 1024 * 1024) throw fail('tooLarge');
  for (const k of ['threadId', 'turnId', 'projectId', 'idempotencyKey']) {
    if (params[k] != null && !(k === 'projectId' && params[k] === '' && method === 'thread/metadata/update') && !validID(params[k])) throw fail('invalidRequest');
  }
  if (method.startsWith('thread/') && !['thread/list', 'thread/start'].includes(method) && !validID(params.threadId)) throw fail('invalidRequest');
  if (['project/read', 'project/update'].includes(method) && !validID(params.projectId)) throw fail('invalidRequest');
  if (params.limit != null && (!Number.isInteger(params.limit) || params.limit < 1 || params.limit > 100)) throw fail('invalidRequest');
  if (params.cursor != null && (typeof params.cursor !== 'string' || !params.cursor.length || Buffer.byteLength(params.cursor) > 16384)) throw fail('invalidRequest');
  if (params.cwd != null && (typeof params.cwd !== 'string' || !params.cwd.startsWith('/') || params.cwd.includes('\0') || Buffer.byteLength(params.cwd) > 4096)) throw fail('invalidRequest');
  if (params.roots != null && (!Array.isArray(params.roots) || !params.roots.length || params.roots.length > 32 || params.roots.some(r => !object(r) || Object.keys(r).some(k => k !== 'path') || typeof r.path !== 'string' || !r.path.startsWith('/') || r.path.includes('\0') || Buffer.byteLength(r.path) > 4096))) throw fail('invalidRequest');
  if (['project/create', 'thread/name/set'].includes(method) && (typeof params.name !== 'string' || !params.name.trim() || Buffer.byteLength(params.name) > 4096)) throw fail('invalidRequest');
  if (method === 'project/create' && (!validID(params.idempotencyKey) || !Array.isArray(params.roots))) throw fail('invalidRequest');
  if (method === 'thread/start' && (typeof params.cwd !== 'string' || !validID(params.projectId))) throw fail('invalidRequest');
  // Reading account state must not trigger token refresh or login.
  if (method === 'account/read' && params.refreshToken !== undefined && params.refreshToken !== false) throw fail('invalidRequest');
  if (method === 'turn/interrupt' && !validID(params.turnId)) throw fail('invalidRequest');
  if (method === 'turn/start') {
    if (!Array.isArray(params.input) || params.input.length !== 1 || !object(params.input[0]) ||
        Object.keys(params.input[0]).some(k => !['type', 'text', 'text_elements'].includes(k)) ||
        params.input[0].type !== 'text' || typeof params.input[0].text !== 'string' || !params.input[0].text.trim() ||
        Buffer.byteLength(params.input[0].text) > 512 * 1024 ||
        (params.input[0].text_elements !== undefined && (!Array.isArray(params.input[0].text_elements) || params.input[0].text_elements.length))) throw fail('invalidRequest');
    if (params.effort != null && !['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra'].includes(params.effort)) throw fail('invalidRequest');
  }
}

export function safeEffectiveConfiguration(result) {
  const policy = result?.approvalPolicy;
  const granular = object(policy) && Object.keys(policy).length === 1 && object(policy.granular) &&
    ['mcp_elicitations', 'rules', 'sandbox_approval'].every(k => typeof policy.granular[k] === 'boolean') &&
    Object.entries(policy.granular).every(([k, v]) => ['mcp_elicitations', 'rules', 'sandbox_approval', 'request_permissions', 'skill_approval'].includes(k) && typeof v === 'boolean');
  return object(result) && object(result.thread) && validID(result.thread.id) &&
    object(result.sandbox) && ['readOnly', 'workspaceWrite'].includes(result.sandbox.type) &&
    (['never', 'untrusted', 'on-request'].includes(policy) || granular) &&
    (result.approvalPolicy === 'never' || result.approvalsReviewer === 'user');
}

export class NativeSession {
  constructor({ WebSocketClass = globalThis.WebSocket, spawnProxy = spawn, emit = () => {}, timeoutMS = 30000 } = {}) {
    if (!Number.isInteger(timeoutMS) || timeoutMS < 1 || timeoutMS > 30000) throw fail('invalidRequest');
    this.WebSocketClass = WebSocketClass; this.spawnProxy = spawnProxy; this.emit = emit; this.timeoutMS = timeoutMS;
    this.pending = new Map(); this.approvals = new Map(); this.resumed = new Map(); this.starting = new Set();
    this.sequence = 0; this.bytes = 0; this.messages = 0;
  }
  async connect(config) {
    if (this.started || !object(config) || Object.keys(config).some(k => !['transport', 'endpoint', 'executable', 'home'].includes(k))) throw fail('invalidRequest');
    this.started = true;
    const opened = new Promise((resolve, reject) => { this.openResolve = resolve; this.openReject = reject; });
    // Transport construction/validation can fail before awaiting this promise.
    // Keep that early failure path free of unhandled rejection side effects.
    opened.catch(() => {});
    this.openTimer = setTimeout(() => this.abort('timeout'), Math.min(this.timeoutMS, 8000));
    try {
    if (config.transport === 'explicitLoopbackWebSocket') {
      const endpoint = validateEndpoint(config.endpoint);
      if (typeof this.WebSocketClass !== 'function') throw fail('unavailable');
      this.socket = new this.WebSocketClass(endpoint);
      this.socket.addEventListener('open', () => this.openResolve?.(), { once: true });
      this.socket.addEventListener('message', e => { if (typeof e.data !== 'string') this.abort('malformed'); else this.message(e.data); });
      this.socket.addEventListener('error', () => this.abort('unavailable'));
      this.socket.addEventListener('close', () => this.abort('disconnected'));
      this.send = frame => this.socket.send(JSON.stringify(frame));
    } else if (config.transport === 'defaultProxy') {
      if (typeof config.executable !== 'string' || !config.executable.startsWith('/') || config.executable.includes('\0') ||
          typeof config.home !== 'string' || !config.home.startsWith('/') || config.home.includes('\0') ||
          Buffer.byteLength(config.executable) > 4096 || Buffer.byteLength(config.home) > 4096) throw fail('invalidRequest');
      // No --listen, --sock guess, configuration overrides, or fallback process.
      this.proxy = this.spawnProxy(config.executable, ['app-server', 'proxy'], {
        env: { HOME: process.env.HOME, CODEX_HOME: config.home, PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8', NO_COLOR: '1' },
        cwd: '/private/tmp', stdio: ['pipe', 'pipe', 'ignore'], detached: true
      });
      this.proxySocket = new ProxyWebSocket({ input: this.proxy.stdin, onOpen: () => this.openResolve?.(),
        onText: text => this.message(text), onFailure: code => this.abort(code) });
      this.proxy.once('spawn', () => {
        this.emit({ kind: 'proxyProcess', pid: this.proxy.pid });
        try { this.proxySocket.start(); } catch (error) { this.abort(error.code || 'unavailable'); }
      });
      this.proxy.once('error', () => this.abort('unavailable'));
      this.proxy.once('exit', () => { this.emit({ kind: 'proxyProcessEnded', pid: this.proxy.pid }); this.abort('disconnected'); });
      this.proxy.stdout.on('data', chunk => this.proxySocket.receive(chunk));
      this.proxy.stdout.once('end', () => this.abort('disconnected'));
      this.proxy.stdin.on('error', () => this.abort('disconnected'));
      this.send = frame => this.proxySocket.sendText(JSON.stringify(frame));
    } else throw fail('invalidRequest');
      await opened;
      const result = await this.rpc('initialize', { clientInfo: { name: 'aitvaras_native', version: '1' }, capabilities: { experimentalApi: true } });
      if (!object(result)) throw fail('malformed');
      this.send({ method: 'initialized', params: {} }); this.ready = true;
      return { transport: config.transport, runtimeIdentityKnown: false, desktopAttachmentVerified: false,
        detail: config.transport === 'defaultProxy' ? 'Connected through the official default control socket proxy. Runtime identity and desktop attachment are not attested.' :
          'Connected to the explicitly reviewed loopback endpoint. Runtime identity and desktop attachment are not attested.' };
    } catch (error) { this.abort(error.code || 'unavailable'); throw error; }
    finally { clearTimeout(this.openTimer); }
  }
  async request(method, params) {
    validateRequest(method, params);
    if (method === 'account/read') params = { ...params, refreshToken: false };
    if (!this.ready || this.failure) throw this.failure || fail('disconnected');
    const threadID = params.threadId;
    if (method === 'turn/start') {
      if (!this.resumed.has(threadID)) throw fail('unreviewedConfiguration');
      if (!safeEffectiveConfiguration(this.resumed.get(threadID))) throw fail('unreviewedConfiguration');
      if (this.starting.has(threadID)) throw fail('busy');
      this.starting.add(threadID);
      try {
        // This prevents known activity, not a cross-client atomic idle reservation.
        // The native API can still steer work started by another client in this gap.
        const fresh = await this.rpc('thread/read', { threadId: threadID, includeTurns: false });
        if (fresh?.thread?.id !== threadID || fresh.thread.status?.type !== 'idle' || fresh.thread.canAcceptDirectInput === false) throw fail('busy');
        return await this.rpc(method, params);
      } finally { this.starting.delete(threadID); }
    }
    const result = await this.rpc(method, params);
    if (['thread/resume', 'thread/start'].includes(method)) {
      if (!object(result?.thread) || !validID(result.thread.id) || (threadID && result.thread.id !== threadID)) throw fail('malformed');
      this.resumed.set(result.thread.id, result);
    }
    if (method === 'thread/unsubscribe') this.resumed.delete(threadID);
    return result;
  }
  rpc(method, params) {
    if (method !== 'initialize' && !methods[method]) return Promise.reject(fail('invalidRequest'));
    if (this.failure) return Promise.reject(this.failure);
    if (this.pending.size >= MAX_PENDING) return Promise.reject(fail('busy'));
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      const timer = setTimeout(() => this.abort('timeout'), this.timeoutMS);
      this.pending.set(id, { resolve, reject, timer });
      try { this.send({ id, method, params }); } catch (error) { this.abort(error.code || 'disconnected'); }
    });
  }
  message(data) {
    if (this.failure) return;
    const size = Buffer.byteLength(data); this.bytes += size; this.messages++;
    if (size > MAX_FRAME || this.bytes > MAX_WIRE || this.messages > 100000) return this.abort('tooLarge');
    let frame; try { frame = JSON.parse(data); } catch { return this.abort('malformed'); }
    if (!object(frame)) return this.abort('malformed');
    if (own(frame, 'method')) {
      if (typeof frame.method !== 'string' || Buffer.byteLength(frame.method) > 256 || !object(frame.params ?? {})) return this.abort('malformed');
      if (own(frame, 'id')) return this.serverRequest(frame);
      if (frame.method === 'serverRequest/resolved') {
        const id = frame.params?.requestId;
        const request = this.approvals.get(JSON.stringify(id));
        if (request) { clearTimeout(request.timer); this.approvals.delete(JSON.stringify(id)); }
      }
      if (frame.method === 'thread/settings/updated' && validID(frame.params?.threadId)) this.resumed.delete(frame.params.threadId);
      this.emit({ kind: 'notification', method: frame.method, params: frame.params ?? {} }); return;
    }
    const request = this.pending.get(frame.id);
    if (!request || own(frame, 'result') === own(frame, 'error')) return this.abort('malformed');
    clearTimeout(request.timer); this.pending.delete(frame.id);
    if (own(frame, 'error')) request.reject(fail(frame.error?.code === -32601 ? 'unsupported' : 'rejected'));
    else request.resolve(frame.result);
  }
  serverRequest(frame) {
    if (!((typeof frame.id === 'string' && frame.id.length && Buffer.byteLength(frame.id) <= 256) || Number.isSafeInteger(frame.id))) return this.abort('malformed');
    const p = frame.params, key = JSON.stringify(frame.id);
    // No tool execution, token refresh, attestation or unknown request handlers.
    if (!serverMethods.has(frame.method) || !validID(p?.threadId) || !validID(p?.turnId) || !this.resumed.has(p.threadId)) {
      try { this.send({ id: frame.id, error: { code: -32601, message: 'No supported scoped user interaction handler' } }); }
      catch { this.abort('disconnected'); }
      return;
    }
    if (this.approvals.has(key) || this.approvals.size >= MAX_PENDING) return this.abort('tooLarge');
    const timer = setTimeout(() => {
      this.approvals.delete(key);
      try { this.send({ id: frame.id, error: { code: -32000, message: 'User interaction expired without approval' } }); }
      catch { this.abort('disconnected'); }
      this.emit({ kind: 'notification', method: 'aitvaras/serverRequestExpired', params: { requestId: frame.id, threadId: p.threadId, turnId: p.turnId } });
    }, 10 * 60 * 1000);
    this.approvals.set(key, { ...frame, timer });
    this.emit({ kind: 'serverRequest', id: frame.id, method: frame.method, params: p });
  }
  respond({ requestID, threadID, turnID, result }) {
    const key = JSON.stringify(requestID), request = this.approvals.get(key);
    if (!request || request.params.threadId !== threadID || request.params.turnId !== turnID || !object(result) || Buffer.byteLength(JSON.stringify(result)) > 128 * 1024) throw fail('approvalScope');
    if (['item/commandExecution/requestApproval', 'item/fileChange/requestApproval'].includes(request.method)) {
      if (Object.keys(result).some(k => k !== 'decision') || !['accept', 'decline', 'cancel'].includes(result.decision)) throw fail('invalidRequest');
      const choices = request.params.availableDecisions;
      if (Array.isArray(choices) && !choices.includes(result.decision)) throw fail('invalidRequest');
    } else if (request.method === 'item/permissions/requestApproval') {
      // No session grants and no synthesized permission widening. The explicit
      // user choice can grant exactly the requested profile, or deny with {}.
      if (Object.keys(result).some(k => !['permissions', 'scope'].includes(k)) || !object(result.permissions) ||
          (result.scope !== undefined && result.scope !== 'turn') ||
          (Object.keys(result.permissions).length && !isDeepStrictEqual(result.permissions, request.params.permissions))) throw fail('invalidRequest');
    } else if (request.method === 'item/tool/requestUserInput') {
      if (Object.keys(result).some(k => k !== 'answers') || !object(result.answers)) throw fail('invalidRequest');
      const ids = new Set((request.params.questions ?? []).map(q => q.id));
      for (const [id, answer] of Object.entries(result.answers)) if (!ids.has(id) || !object(answer) || Object.keys(answer).some(k => k !== 'answers') ||
        !Array.isArray(answer.answers) || answer.answers.length > 16 || answer.answers.some(a => typeof a !== 'string' || Buffer.byteLength(a) > 16384)) throw fail('invalidRequest');
    } else if (request.method === 'mcpServer/elicitation/request') {
      if (Object.keys(result).some(k => !['action', 'content'].includes(k)) || !['accept', 'decline', 'cancel'].includes(result.action)) throw fail('invalidRequest');
    } else throw fail('unsupported');
    this.send({ id: requestID, result }); clearTimeout(request.timer); this.approvals.delete(key);
  }
  abort(code = 'disconnected') {
    if (this.failure) return;
    this.failure = fail(code); this.ready = false; clearTimeout(this.openTimer); this.openReject?.(this.failure);
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(this.failure); } this.pending.clear();
    for (const p of this.approvals.values()) clearTimeout(p.timer); this.approvals.clear(); this.resumed.clear();
    try { this.socket?.close(1000); } catch {}
    this.proxySocket?.close();
    // This is solely the child proxy we created, never the shared daemon.
    if (this.proxy) { this.proxy.stdin.end(); this.proxy.kill('SIGTERM'); const child = this.proxy; const t = setTimeout(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); }, 250); t.unref(); }
    this.emit({ kind: 'disconnected', code });
  }
}

async function main() {
  let stopped = false, buffer = Buffer.alloc(0), count = 0;
  const codes = new Set(['invalidRequest', 'invalidEndpoint', 'unavailable', 'unsupported', 'rejected', 'timeout', 'tooLarge', 'malformed', 'disconnected', 'busy', 'approvalScope', 'unreviewedConfiguration']);
  const emit = frame => {
    if (stopped) return;
    if (process.stdout.writableLength > 8 * 1024 * 1024) { session.abort('tooLarge'); stopped = true; process.exitCode = 1; process.stdin.destroy(); return; }
    process.stdout.write(JSON.stringify(frame) + '\n');
  };
  const session = new NativeSession({ emit });
  const stop = () => { session.abort(); stopped = true; process.stdin.destroy(); };
  process.once('SIGTERM', stop); process.once('SIGINT', stop);
  const inputTimer = setTimeout(() => { session.abort('timeout'); process.stdin.destroy(); }, 8000);
  const lifetime = setTimeout(stop, 12 * 60 * 60 * 1000); lifetime.unref();
  async function dispatch(command) {
    const id = command?.id;
    try {
      if (!object(command) || !validID(id) || Object.keys(command).some(k => !['id', 'op', 'configuration', 'method', 'params', 'requestID', 'threadID', 'turnID', 'result'].includes(k))) throw fail('invalidRequest');
      let result;
      if (command.op === 'connect') { clearTimeout(inputTimer); result = await session.connect(command.configuration); }
      else if (command.op === 'request') result = await session.request(command.method, command.params);
      else if (command.op === 'respond') { session.respond(command); result = {}; }
      else if (command.op === 'disconnect') { session.abort(); result = {}; }
      else throw fail('invalidRequest');
      emit({ kind: 'result', id, result });
    } catch (error) { emit({ kind: 'error', id, code: codes.has(error.code) ? error.code : 'unavailable' }); }
  }
  try {
    for await (const chunk of process.stdin) {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_FRAME) throw fail('tooLarge');
      let end;
      while ((end = buffer.indexOf(10)) !== -1) {
        const line = buffer.subarray(0, end); buffer = buffer.subarray(end + 1);
        if (!line.length || ++count > 100000) throw fail('tooLarge');
        let command; try { command = JSON.parse(line.toString('utf8')); } catch { throw fail('invalidRequest'); }
        // Keep processing replies while native requests are pending. Outstanding
        // native work is separately bounded inside the session.
        void dispatch(command);
      }
    }
  } catch (error) { session.abort(codes.has(error.code) ? error.code : 'malformed'); }
  finally { clearTimeout(inputTimer); clearTimeout(lifetime); session.abort(); }
}
if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
