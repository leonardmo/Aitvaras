// Read-only attachment to an explicitly configured native runtime. Never starts
// Codex, discovers endpoints, reads a profile, or sends a model/auth request.
import { fileURLToPath } from 'node:url';

const MAX_INPUT = 4096, MAX_FRAME = 512 * 1024, MAX_WIRE = 1024 * 1024, MAX_MESSAGES = 256;
const fail = code => Object.assign(new Error(code), { code });
const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const allowedMethods = new Set(['initialize', 'project/list']);

// Validate the original authority before URL normalization: WHATWG URL accepts
// noncanonical IPv4 spellings such as 127.1 and decimal integer addresses.
// Hostnames (including localhost) are deliberately not resolved or trusted.
export function validateEndpoint(endpoint) {
  if (typeof endpoint !== 'string' || Buffer.byteLength(endpoint) > 2048 ||
      !/^ws:\/\/(127\.0\.0\.1|\[::1\]):([1-9][0-9]{0,4})(\/[^\s\\?#%]*)?$/.test(endpoint) ||
      /[\u0000-\u0020\u007f-\uffff]/.test(endpoint)) throw fail('invalidEndpoint');
  const port = Number(endpoint.match(/^ws:\/\/(?:127\.0\.0\.1|\[::1\]):([0-9]+)/)[1]);
  if (port > 65535) throw fail('invalidEndpoint');
  let url;
  try { url = new URL(endpoint); } catch { throw fail('invalidEndpoint'); }
  if (url.protocol !== 'ws:' || !['127.0.0.1', '[::1]'].includes(url.hostname) ||
      port > 65535 || url.username || url.password || url.search || url.hash) {
    throw fail('invalidEndpoint');
  }
  return url.href;
}

export class SharedRuntimeProbe {
  constructor({ WebSocketClass = globalThis.WebSocket, timeoutMS = 5000 } = {}) {
    if (!Number.isInteger(timeoutMS) || timeoutMS < 1 || timeoutMS > 5000) throw fail('invalidRequest');
    this.WebSocketClass = WebSocketClass; this.timeoutMS = timeoutMS;
    this.pending = new Map(); this.sequence = 0; this.bytes = 0; this.messages = 0;
  }

  async probe(endpoint, { signal } = {}) {
    const address = validateEndpoint(endpoint);
    if (this.started) throw fail('invalidRequest');
    this.started = true;
    if (signal?.aborted) throw fail('cancelled');
    if (typeof this.WebSocketClass !== 'function') throw fail('unavailable');
    let abortListener;
    try {
      const opened = new Promise((resolve, reject) => { this.openResolve = resolve; this.openReject = reject; });
      this.socket = new this.WebSocketClass(address);
      this.socket.addEventListener('open', () => this.openResolve?.(), { once: true });
      this.socket.addEventListener('message', event => this.message(event.data));
      this.socket.addEventListener('error', () => this.abort('unavailable'));
      this.socket.addEventListener('close', () => this.abort('unavailable'));
      this.timer = setTimeout(() => this.abort('timeout'), this.timeoutMS);
      abortListener = () => this.abort('cancelled');
      signal?.addEventListener('abort', abortListener, { once: true });
      if (signal?.aborted) this.abort('cancelled');
      await opened;
      this.openResolve = this.openReject = undefined;
      const initialized = await this.rpc('initialize', {
        clientInfo: { name: 'aitvaras_read_only_probe', version: '1' },
        capabilities: { experimentalApi: true }
      });
      if (!object(initialized)) throw fail('malformed');
      // No userAgent/PID/endpoint inference establishes a shared desktop runtime.
      // The reviewed initialize response does not supply a stable runtime ID.
      this.notifyInitialized();
      const projects = await this.rpc('project/list', { limit: 1, cursor: null });
      if (!object(projects) || !Array.isArray(projects.data) || projects.data.length > 1 ||
          !Object.hasOwn(projects, 'nextCursor') ||
          !(projects.nextCursor === null || (typeof projects.nextCursor === 'string' &&
            Buffer.byteLength(projects.nextCursor) <= 16384)) || !projects.data.every(object)) throw fail('malformed');
      if (this.failure) throw this.failure;
      // Never export project names, roots, IDs, cursors, or arbitrary server text.
      return { connected: true, transport: 'explicitLoopbackWebSocket', projectListAvailable: true,
        runtimeIdentity: 'unknown', desktopAttachmentVerified: false, continuationSupported: false };
    } finally {
      clearTimeout(this.timer);
      signal?.removeEventListener('abort', abortListener);
      this.abort('cancelled');
      try { this.socket?.close(1000); } catch {}
    }
  }

  rpc(method, params) {
    if (!allowedMethods.has(method)) return Promise.reject(fail('forbiddenMethod'));
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      const id = ++this.sequence;
      this.pending.set(id, { resolve, reject, method });
      try { this.socket.send(JSON.stringify({ id, method, params })); }
      catch { this.abort('unavailable'); }
    });
  }

  notifyInitialized() {
    if (this.failure) throw this.failure;
    try { this.socket.send(JSON.stringify({ method: 'initialized', params: {} })); }
    catch { throw fail('unavailable'); }
  }

  message(data) {
    if (this.failure) return;
    if (typeof data !== 'string') { this.abort('malformed'); return; }
    const bytes = Buffer.byteLength(data);
    this.bytes += bytes; this.messages++;
    if (bytes > MAX_FRAME || this.bytes > MAX_WIRE || this.messages > MAX_MESSAGES) {
      this.abort('tooLarge'); return;
    }
    let frame;
    try { frame = JSON.parse(data); } catch { this.abort('malformed'); return; }
    if (!object(frame)) { this.abort('malformed'); return; }
    if (Object.hasOwn(frame, 'method')) {
      // Requests from the server are never approved or dispatched. Notifications
      // from unrelated runtime activity are ignored within the total wire bound.
      if (typeof frame.method !== 'string' || Object.hasOwn(frame, 'id')) this.abort('serverRequest');
      return;
    }
    const request = this.pending.get(frame.id);
    if (!request || Object.hasOwn(frame, 'result') === Object.hasOwn(frame, 'error')) {
      this.abort('malformed'); return;
    }
    this.pending.delete(frame.id);
    if (Object.hasOwn(frame, 'error')) {
      request.reject(fail(object(frame.error) && frame.error.code === -32601 ? 'unsupported' : 'rejected'));
    } else request.resolve(frame.result);
  }

  abort(code) {
    if (this.failure) return;
    this.failure = fail(code);
    this.openReject?.(this.failure);
    for (const request of this.pending.values()) request.reject(this.failure);
    this.pending.clear();
    try { this.socket?.close(1000); } catch {}
  }
}

async function main() {
  const controller = new AbortController();
  process.once('SIGTERM', () => controller.abort());
  process.once('SIGINT', () => controller.abort());
  // The parent supplies one bounded JSON request and then closes stdin.
  let input = Buffer.alloc(0);
  const inputTimer = setTimeout(() => { process.stdout.write('{"error":"timeout"}\n'); process.exit(1); }, 2000);
  try {
    for await (const chunk of process.stdin) {
      if (input.length + chunk.length > MAX_INPUT) throw fail('tooLarge');
      input = Buffer.concat([input, chunk]);
    }
    clearTimeout(inputTimer);
    let request;
    try { request = JSON.parse(input.toString('utf8')); } catch { throw fail('invalidRequest'); }
    if (!object(request) || request.operation !== 'probe' ||
        Object.keys(request).some(key => !['operation', 'endpoint'].includes(key))) throw fail('invalidRequest');
    const result = await new SharedRuntimeProbe().probe(request.endpoint, { signal: controller.signal });
    process.stdout.write(JSON.stringify({ result }) + '\n', () => process.exit(0));
  } catch (error) {
    clearTimeout(inputTimer);
    const codes = ['invalidEndpoint', 'invalidRequest', 'unavailable', 'unsupported', 'rejected',
      'timeout', 'tooLarge', 'malformed', 'cancelled', 'serverRequest'];
    process.stdout.write(JSON.stringify({ error: codes.includes(error.code) ? error.code : 'unavailable' }) + '\n', () => process.exit(1));
  }
}

if (process.argv[1] === fileURLToPath(import.meta.url)) await main();
