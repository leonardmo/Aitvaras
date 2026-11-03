// On-demand official SDK bridge. No credential extraction, custom OAuth, API keys,
// paid status prompts, native-session attachment, shell tools, or prompt replay.
import fs from 'node:fs/promises';
import { constants } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { createRequire } from 'node:module';

export const SDK_VERSION = '0.3.306';
export const CLI_VERSION = '2.1.300';
const MAX_LINE = 262144, MAX_OUTPUT = 2 * 1024 * 1024;
const MAX_HISTORY_BYTES = 10_000_000, MAX_HISTORY_OUTPUT = 64 * 1024 * 1024;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const codes = new Set(['unavailable','disabled','busy','invalidRequest','unsupported','unsafeProfile','unsafeConfig','insecureCredentials','ownership','signInRequired','modelUnavailable','interruptedUnknown','timeout','tooLarge','malformed']);
const fail = code => { throw Object.assign(new Error(code), { code }); };
const boundedString = (s, n) => typeof s === 'string' && Buffer.byteLength(s) <= n && !s.includes('\0');
export function namespace(mode, directory) { return createHash('sha256').update(`${mode}\n${directory}`).digest('hex'); }
export function subscriptionAccount(account) {
  return account?.apiProvider === 'firstParty' && account?.tokenSource === 'claude.ai'
    && account?.apiKeySource === 'none' && ['pro','max','team','enterprise'].includes(account?.subscriptionType?.toLowerCase());
}
export function verifiedSubscriptionAccount(account, status) {
  const plan = value => typeof value === 'string' ? value.trim().toLowerCase().replace(/^claude\s+/, '') : '';
  // The SDK's optional credential-source fields are absent in the real pinned
  // CLI, and its plan label is e.g. "Claude Pro", not "pro". Obtain independent
  // official auth-status evidence instead of interpreting missing as signed out
  // or accepting a plan label alone as subscription authentication.
  if (status?.loggedIn !== true || status.authMethod !== 'claude.ai'
      || status.apiProvider !== 'firstParty' || account?.apiProvider !== 'firstParty'
      || !['pro','max','team','enterprise'].includes(plan(status.subscriptionType))
      || plan(account.subscriptionType) !== plan(status.subscriptionType)
      || (account.tokenSource != null && account.tokenSource !== 'claude.ai')
      || (account.apiKeySource != null && account.apiKeySource !== 'none')
      || !boundedString(account.email, 512) || !account.email
      || !boundedString(status.email, 512) || account.email.toLowerCase() !== status.email.toLowerCase()
      || !boundedString(status.orgId, 512) || !status.orgId
      || !boundedString(account.organization, 512) || !account.organization
      || ![status.orgId, status.orgName].includes(account.organization)) return null;
  return { apiProvider: 'firstParty', tokenSource: 'claude.ai', apiKeySource: 'none',
    subscriptionType: plan(status.subscriptionType), email: status.email, organization: status.orgId };
}
export function accountNamespace(base, account) {
  if (!subscriptionAccount(account)) return namespace(base, 'signed-out');
  // Non-secret official metadata is hashed, never logged or persisted verbatim.
  // Missing stable account metadata fails closed instead of merging accounts.
  if (!boundedString(account.email, 512) || !account.email || !boundedString(account.organization, 512) || !account.organization) fail('unsupported');
  return namespace(base, `${account.email.toLowerCase()}\n${account.organization}`);
}
export function cleanEnvironment(home, configDirectory, mode = 'separate') {
  return { HOME: home, PATH: '/usr/bin:/bin', LANG: 'en_US.UTF-8', NO_COLOR: '1',
    ...(mode === 'separate' ? { CLAUDE_CONFIG_DIR: configDirectory } : {}),
    CLAUDE_CODE_DISABLE_AUTO_MEMORY: '1', CLAUDE_CODE_NO_MODEL_FALLBACK: '1',
    CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_AUTOUPDATER: '1' };
}
export async function ensureSecureCredentialStorage(configDirectory, metadata = fs.lstat) {
  // Presence only. Never read, copy, delete or migrate credential contents.
  try { await metadata(join(configDirectory, '.credentials.json')); }
  catch (error) { if (error.code === 'ENOENT') return; fail('insecureCredentials'); }
  fail('insecureCredentials');
}
async function ensureUnmanagedConfiguration(home, configDirectory) {
  // Parent-managed settings cannot override real IT policy. Refuse its presence
  // rather than assuming that SDK settings suppress mandatory managed hooks.
  for (const path of ['/Library/Application Support/ClaudeCode/managed-settings.json',
    '/Library/Application Support/ClaudeCode/managed-settings.d',
    '/Library/Managed Preferences/com.anthropic.claudecode.plist',
    join(home, 'Library/Managed Preferences/com.anthropic.claudecode.plist'),
    join(configDirectory, 'remote-settings.json')]) {
    try { await fs.lstat(path); fail('unsafeConfig'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
}
export function optionsFor(request, environment, cwd) {
  return { cwd, env: environment, pathToClaudeCodeExecutable: request.executable,
    settingSources: [], tools: [], allowedTools: [], disallowedTools: [],
    skills: [], plugins: [], agents: {}, hooks: {}, strictMcpConfig: true,
    permissionMode: 'dontAsk', canUseTool: async () => ({ behavior: 'deny', message: 'Only the approved project broker is available.' }),
    settings: { disableAllHooks: true, autoMemoryEnabled: false, enabledPlugins: {},
      apiKeyHelper: '', env: {}, permissions: { defaultMode: 'dontAsk' } },
    managedSettings: { disableAllHooks: true },
    systemPrompt: 'You are the Aitvaras assistant. Only explicitly provided context and the approved read-only project broker are available. Never claim native Claude app control.\n' + (request.context ?? ''),
    includePartialMessages: true, persistSession: request.operation === 'run',
    enableFileCheckpointing: false, maxTurns: 32,
    ...(request.model ? { model: request.model } : {}), ...(request.effort ? { effort: request.effort } : {}),
    ...(request.operation === 'run' && request.sessionID ? { resume: request.sessionID } : {}) };
}
export async function ownedHistory(request, sdk, cwd) {
  if (!['getSessionInfo','getSessionMessages'].every(name => typeof sdk[name] === 'function')) fail('unsupported');
  const id = request.sessionID;
  const validInfo = info => {
    if (!info || info.sessionId !== id || info.cwd !== cwd || !Number.isSafeInteger(info.lastModified)
        || info.lastModified < 0 || !Number.isSafeInteger(info.fileSize) || info.fileSize < 0) fail('ownership');
    if (info.fileSize > MAX_HISTORY_OUTPUT) fail('tooLarge');
    return `${info.lastModified}:${info.fileSize}`;
  };
  const initial = validInfo(await sdk.getSessionInfo(id, { dir: cwd }));
  const messages = [], seen = new Set();
  let bytes = 0, finalPage, finalOffset;
  for (let page = 0; page < 100; page++) {
    const offset = page * 50;
    const rows = await sdk.getSessionMessages(id, { dir: cwd, limit: 50, offset, includeSystemMessages: false });
    if (!Array.isArray(rows) || rows.length > 50) fail('malformed');
    for (const row of rows) {
      if (!row || !UUID.test(row.uuid ?? '') || row.session_id !== id || !['user','assistant','system'].includes(row.type) || seen.has(row.uuid)) fail('malformed');
      seen.add(row.uuid);
      if (row.type === 'system' || row.parent_tool_use_id != null || row.parent_agent_id != null) continue;
      const content = row.message?.content;
      let text = '';
      if (typeof content === 'string') text = content;
      else if (Array.isArray(content)) text = content.filter(block => block?.type === 'text').map(block => {
        if (typeof block.text !== 'string') fail('malformed'); return block.text;
      }).join('\n');
      if (!text.trim()) continue;
      bytes += Buffer.byteLength(text);
      if (bytes > MAX_HISTORY_BYTES) fail('tooLarge');
      messages.push({ id: row.uuid, role: row.type, text });
    }
    if (rows.length < 50) { finalPage = rows; finalOffset = offset; break; }
  }
  if (!finalPage) fail('tooLarge');
  // Local history APIs do not offer a frozen snapshot. Require stable file
  // metadata around the full scan and an exact final-page reread before publish.
  if (validInfo(await sdk.getSessionInfo(id, { dir: cwd })) !== initial) fail('busy');
  const fence = await sdk.getSessionMessages(id, { dir: cwd, limit: 50, offset: finalOffset, includeSystemMessages: false });
  if (JSON.stringify(fence) !== JSON.stringify(finalPage)
      || validInfo(await sdk.getSessionInfo(id, { dir: cwd })) !== initial) fail('busy');
  return { sessionID: id, profileNamespace: request.expectedNamespace, messages, complete: true, observedAt: Date.now() };
}
async function directory(path) {
  if (!boundedString(path, 4096) || !path.startsWith('/') || resolve(path) !== path) fail('unsafeProfile');
  let current = '/';
  for (const part of path.split('/').filter(Boolean)) {
    current = join(current, part);
    try { await fs.mkdir(current, { mode: 0o700 }); } catch (e) { if (e.code !== 'EEXIST') throw e; }
    const stat = await fs.lstat(current);
    if (!stat.isDirectory() || stat.isSymbolicLink()) fail('unsafeProfile');
  }
  const stat = await fs.stat(path);
  if (stat.uid !== process.getuid() || (stat.mode & 0o022)) fail('unsafeProfile');
}
async function smallFile(path, limit = 8192) {
  const file = await fs.open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try { const stat = await file.stat(); if (!stat.isFile() || stat.nlink !== 1 || stat.size > limit) fail('unsafeProfile'); return await file.readFile('utf8'); }
  finally { await file.close(); }
}

export async function runBridge(request, sdk, io, dependencies) {
  if (!request || !['status','run','history'].includes(request.operation) || !['shared','separate'].includes(request.accountMode)
      || !boundedString(request.profileNamespace, 64) || !/^[a-f0-9]{64}$/.test(request.profileNamespace)) fail('invalidRequest');
  const running = request.operation === 'run';
  const history = request.operation === 'history';
  if (history && (!UUID.test(request.sessionID ?? '') || !/^[a-f0-9]{64}$/.test(request.expectedNamespace ?? ''))) fail('invalidRequest');
  if (running && (!boundedString(request.prompt, 65536) || !request.prompt.trim()
      || !boundedString(request.context, 65536) || !boundedString(request.model, 256) || !request.model
      || (request.effort != null && !['low','medium','high','xhigh','max'].includes(request.effort))
      || (request.sessionID != null && !UUID.test(request.sessionID))
      || (request.userMessageID != null && !UUID.test(request.userMessageID)))) fail('invalidRequest');
  let release, endPrompt;
  const promptReady = new Promise(r => { release = r; });
  const holdOpen = new Promise(r => { endPrompt = r; });
  const prompt = async function* () {
    const message = await promptReady;
    if (message) yield { type: 'user', message: { role: 'user', content: message }, parent_tool_use_id: null,
      session_id: sessionID, uuid: request.userMessageID ?? randomUUID() };
    await holdOpen;
  };
  const sessionID = request.sessionID ?? randomUUID();
  const options = optionsFor(request, dependencies.environment, dependencies.cwd);
  if (!request.sessionID && running) options.sessionId = sessionID;
  options.spawnClaudeCodeProcess = dependencies.spawn;
  options.stderr = () => {};
  const names = ['aitvaras_project_list','aitvaras_project_read'];
  if (running && request.projectRootCount > 0) {
    const z = dependencies.z;
    const tools = names.map(name => sdk.tool(name,
      name.endsWith('_list') ? 'List an approved project directory. Root is an approved zero-based index; path is relative.' : 'Read bounded UTF-8 text in an approved project. Root is a zero-based index; path is relative.',
      { root: z.number().int().min(0).max(request.projectRootCount - 1), path: z.string().max(4096) }, async args => {
        if (io.stopped()) fail('interruptedUnknown');
        const id = randomUUID();
        const reply = await io.request({ event: 'projectToolRequest', id, tool: name, arguments: args }, 'projectToolResult', id);
        if (!boundedString(reply.text, 65536) || typeof reply.success !== 'boolean') fail('malformed');
        return { content: [{ type: 'text', text: reply.text }], isError: !reply.success };
      }));
    options.mcpServers = { aitvaras: sdk.createSdkMcpServer({ name: 'aitvaras', version: '1.0.0', tools }) };
    options.allowedTools = names.map(name => `mcp__aitvaras__${name}`);
  } else options.mcpServers = {};
  let query, delivered = false, terminal = false, acknowledged = false, providerFailure = null;
  let pendingStream = '', lastAssistantText = '', textBytes = 0;
  const text = value => {
    if (!boundedString(value, MAX_OUTPUT)) fail('malformed');
    if (!value) return;
    textBytes += Buffer.byteLength(value);
    if (textBytes > MAX_OUTPUT) fail('tooLarge');
    io.emit({ event: 'textDelta', text: value });
  };
  try {
    if ((running || history) && request.sessionID) await dependencies.verifyOwnership(sessionID, request.expectedNamespace);
    query = sdk.query({ prompt: prompt(), options });
    io.setInterrupt(async () => { if (delivered) { try { await query.interrupt(); } catch {} } else release(null); });
    const initialization = await query.initializationResult();
    if (initialization.claude_code_version !== CLI_VERSION) fail('unsupported');
    const account = await query.accountInfo();
    await dependencies.checkCredentialStorage?.();
    const verifiedAccount = verifiedSubscriptionAccount(account, await dependencies.authenticationStatus());
    const authenticated = verifiedAccount != null;
    const actualNamespace = accountNamespace(request.profileNamespace, verifiedAccount);
    const models = await query.supportedModels();
    if (!Array.isArray(models) || models.length > 100) fail('malformed');
    const rows = models.map(model => {
      if (!boundedString(model.value, 256) || !boundedString(model.displayName, 256)) fail('malformed');
      const efforts = model.supportedEffortLevels ?? [];
      if (!Array.isArray(efforts) || efforts.some(e => !['low','medium','high','xhigh','max'].includes(e))) fail('malformed');
      return { id: model.value, displayName: model.displayName, efforts };
    });
    if (request.operation === 'status') {
      io.emit({ event: 'result', result: { authenticated, models: authenticated ? rows : [], usageWindows: null,
        accountLabel: authenticated ? verifiedAccount.email : null, profileNamespace: actualNamespace } });
      return;
    }
    if (!authenticated) fail('signInRequired');
    if (request.expectedNamespace !== actualNamespace) fail('ownership');
    if (request.sessionID) await dependencies.verifyOwnership(sessionID, actualNamespace);
    if (history) {
      const snapshot = await ownedHistory(request, sdk, dependencies.cwd);
      await dependencies.checkCredentialStorage?.();
      io.emit({ event: 'history', snapshot: { ...snapshot, messages: [] } });
      for (const message of snapshot.messages) {
        let append = false;
        for (const chunk of message.text.matchAll(/[\s\S]{1,8192}/gu)) {
          io.emit({ event: 'historyMessage', id: message.id, role: message.role, text: chunk[0], append });
          append = true;
        }
      }
      io.emit({ event: 'result' });
      return;
    }
    const selected = rows.find(m => m.id === request.model);
    if (!selected || (request.effort && !selected.efforts.includes(request.effort))) fail('modelUnavailable');
    if (!request.sessionID) {
      await io.request({ event: 'sessionCreated', id: sessionID }, 'ackSession', sessionID);
      await dependencies.recordOwnership(sessionID, actualNamespace);
    }
    const deliveryID = randomUUID();
    await dependencies.checkCredentialStorage?.();
    await io.request({ event: 'deliveryAttempt', id: deliveryID }, 'ackDelivery', deliveryID);
    if (io.stopped()) fail('interruptedUnknown');
    // No prompt enters the SDK's iterator until the durable app acknowledgement.
    delivered = true;
    release(request.prompt);
    for await (const message of query) {
      if (message.session_id && message.session_id !== sessionID) fail('ownership');
      // A locally generated delivery UUID is not provider acknowledgement.
      // The official SDK's first response/message UUID is the available evidence;
      // the SDK does not expose a Codex-style turn identifier.
      if (!acknowledged && ['assistant','stream_event','result'].includes(message.type)) {
        if (message.session_id !== sessionID || !UUID.test(message.uuid ?? '')) fail('malformed');
        io.emit({ event: 'turnStarted', id: message.uuid }); acknowledged = true;
      }
      if (message.type === 'stream_event' && message.event?.type === 'content_block_delta'
          && message.event.delta?.type === 'text_delta') {
        text(message.event.delta.text); pendingStream += message.event.delta.text;
      }
      if (message.type === 'assistant') {
        if (message.error) {
          providerFailure = message.error === 'authentication_failed' ? 'authenticationRequired'
            : message.error === 'rate_limit' ? 'usageLimit' : 'providerRejected';
          if (!UUID.test(message.uuid ?? '')) fail('malformed');
          io.emit({ event: 'providerFailure', code: providerFailure, id: message.uuid });
          // SDK-generated error prose is not an assistant answer or canonical
          // message. Keep only the typed reason, never parse/display its text.
          continue;
        }
        const content = message.message?.content;
        if (!Array.isArray(content)) fail('malformed');
        // Thinking, tool calls and other media are not flattened into prose.
        const complete = content.filter(block => block?.type === 'text').map(block => {
          if (!boundedString(block.text, MAX_OUTPUT)) fail('malformed'); return block.text;
        }).join('');
        if (!complete.startsWith(pendingStream)) fail('malformed');
        text(complete.slice(pendingStream.length));
        lastAssistantText = complete; pendingStream = '';
        if (message.parent_tool_use_id == null && message.parent_agent_id == null && complete) {
          if (!UUID.test(message.uuid ?? '')) fail('malformed');
          io.emit({ event: 'assistantMessage', id: message.uuid, text: complete });
        }
      }
      if (message.type === 'result') {
        if (message.is_error === true && !providerFailure) {
          providerFailure = message.api_error_status === 401 ? 'authenticationRequired' : 'providerRejected';
        }
        if (!providerFailure && message.is_error !== true && message.subtype === 'success' && typeof message.result === 'string' && message.result) {
          if (!textBytes) text(message.result);
          else if (pendingStream) {
            if (!message.result.startsWith(pendingStream)) fail('malformed');
            text(message.result.slice(pendingStream.length));
          } else if (message.result !== lastAssistantText) fail('malformed');
        }
        // A successful provider envelope with no text is not a successful text
        // answer. Keep its actual token usage but expose a failed/no-answer turn.
        const state = !providerFailure && message.is_error !== true && message.subtype === 'success' && textBytes > 0 ? 'completed' : 'failed';
        const usage = message.usage ?? {};
        if (providerFailure) io.emit({ event: 'providerFailure', code: providerFailure });
        io.emit({ event: 'completed', state, inputTokens: usage.input_tokens ?? null, outputTokens: usage.output_tokens ?? null });
        terminal = true; break;
      }
    }
    if (!terminal) fail(delivered ? 'interruptedUnknown' : 'unavailable');
    io.emit({ event: 'result' });
  } finally { release(null); endPrompt(); query?.close(); }
}

export async function main() {
  let outputBytes = 0, buffer = Buffer.alloc(0), request, settled = false, stopped = false, interrupt;
  const pending = new Map(), children = new Set();
  let receiveRequest, rejectRequest;
  const first = new Promise((r,j) => { receiveRequest = r; rejectRequest = j; });
  const emit = frame => {
    const line = JSON.stringify(frame) + '\n'; outputBytes += Buffer.byteLength(line);
    if (Buffer.byteLength(line) > MAX_LINE || outputBytes > (request?.operation === 'history' ? MAX_HISTORY_OUTPUT : MAX_OUTPUT)) fail('tooLarge');
    process.stdout.write(line);
  };
  const stop = () => {
    if (stopped) return; stopped = true;
    for (const { reject } of pending.values()) reject(Object.assign(new Error(), { code: 'interruptedUnknown' }));
    pending.clear(); rejectRequest(Object.assign(new Error(), { code: 'interruptedUnknown' }));
    Promise.resolve(interrupt?.()).catch(() => {});
    setTimeout(() => { for (const child of children) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } process.exit(1); }, 1500).unref();
  };
  process.on('SIGTERM', stop); process.on('SIGINT', stop);
  process.stdin.on('end', () => { if (!settled) stop(); });
  process.stdin.on('data', chunk => {
    try {
      buffer = Buffer.concat([buffer, chunk]);
      if (buffer.length > MAX_LINE) fail('tooLarge');
      while (buffer.includes(10)) {
        const offset = buffer.indexOf(10), line = buffer.subarray(0, offset); buffer = buffer.subarray(offset + 1);
        const value = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(line));
        if (!request) { request = value; receiveRequest(value); continue; }
        if (value.command === 'interrupt') { stop(); continue; }
        const key = `${value.command}:${value.id}`, waiting = pending.get(key);
        if (!waiting) fail('malformed'); pending.delete(key); waiting.resolve(value);
      }
    } catch { stop(); }
  });
  let timer = setTimeout(stop, 43_000); timer.unref();
  try {
    const req = await first;
    if (req.operation === 'run') { clearTimeout(timer); timer = setTimeout(stop, 15 * 60 * 1000); timer.unref(); }
    for (const key of ['profileDirectory','configDirectory','executable','home','sdkDirectory'])
      if (!boundedString(req[key], 4096) || !req[key].startsWith('/')) fail('invalidRequest');
    if (namespace(req.accountMode, req.configDirectory) !== req.profileNamespace) fail('unsafeProfile');
    const sdkRoot = resolve(req.sdkDirectory, 'node_modules/@anthropic-ai/claude-agent-sdk');
    const manifest = JSON.parse(await smallFile(join(sdkRoot, 'package.json')));
    if (manifest.name !== '@anthropic-ai/claude-agent-sdk' || manifest.version !== SDK_VERSION) fail('unsupported');
    // Managed hooks can run before SDK initialization. Unknown host policy is not
    // silently weakened: installations with on-disk or MDM policy are refused.
    await ensureUnmanagedConfiguration(req.home, req.configDirectory);
    const environment = cleanEnvironment(req.home, req.configDirectory, req.accountMode);
    // Official history functions resolve the config from their host process,
    // not Query.options.env. This affects this short-lived helper only.
    for (const key of Object.keys(process.env)) delete process.env[key];
    Object.assign(process.env, environment);
    await ensureSecureCredentialStorage(req.configDirectory);
    const version = await promisify(execFile)(req.executable, ['--version'], { env: environment, timeout: 5000, maxBuffer: 8192 });
    if (version.stdout.trim() !== `${CLI_VERSION} (Claude Code)`) fail('unsupported');
    await directory(req.profileDirectory);
    if (req.accountMode === 'separate') await directory(req.configDirectory);
    const cwd = join(req.profileDirectory, 'claude-live', req.profileNamespace);
    await directory(cwd); await directory(join(cwd, 'owned'));
    // The native connector holds an OS advisory lease throughout this process.
    // Unlike an exclusive sentinel file, it is released by the OS after a crash.
    if (req.sessionID && !UUID.test(req.sessionID)) fail('invalidRequest');
    const sdk = await import(pathToFileURL(join(sdkRoot, 'sdk.mjs')).href);
    if (!['query','tool','createSdkMcpServer'].every(key => typeof sdk[key] === 'function')) fail('unsupported');
    const require = createRequire(join(sdkRoot, 'package.json'));
    const z = require('zod/v4');
    await runBridge(req, sdk, {
      emit, stopped: () => stopped, setInterrupt: callback => { interrupt = callback; },
      request: (frame, command, id) => new Promise((resolve, reject) => {
        if (stopped) { reject(Object.assign(new Error(), { code: 'interruptedUnknown' })); return; }
        const key = `${command}:${id}`;
        const timeout = setTimeout(() => { pending.delete(key); reject(Object.assign(new Error(), { code: 'timeout' })); }, 30000);
        pending.set(key, { resolve: value => { clearTimeout(timeout); resolve(value); }, reject: error => { clearTimeout(timeout); reject(error); } });
        emit(frame);
      })
    }, { cwd, environment, z, authenticationStatus: async () => {
      const pending = promisify(execFile)(req.executable, ['auth', 'status'],
        { env: environment, cwd, timeout: 5000, maxBuffer: 32768, detached: true });
      const child = pending.child;
      if (child?.pid) {
        children.add(child); emit({ event: 'processGroup', pid: child.pid });
        child.once('exit', () => { children.delete(child); emit({ event: 'processGroupEnded', pid: child.pid }); });
      }
      let output;
      try { output = (await pending).stdout; }
      catch (error) {
        // Signed-out status may use exit 1. Never publish native diagnostics.
        if (error.code !== 1 || typeof error.stdout !== 'string') fail('unavailable');
        output = error.stdout;
      }
      try { return JSON.parse(output); } catch { fail('malformed'); }
    }, checkCredentialStorage: async () => {
      await ensureSecureCredentialStorage(req.configDirectory);
      await ensureUnmanagedConfiguration(req.home, req.configDirectory);
    },
      verifyOwnership: async (id, account) => {
        try { if ((await smallFile(join(cwd, 'owned', `${id}.json`))) !== JSON.stringify({ namespace: account, id })) fail('ownership'); }
        catch { fail('ownership'); }
      },
      recordOwnership: async (id, account) => {
        const file = await fs.open(join(cwd, 'owned', `${id}.json`), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
        try { await file.writeFile(JSON.stringify({ namespace: account, id })); await file.sync(); } finally { await file.close(); }
      },
      spawn: options => {
        if (stopped || options.command !== req.executable) fail('unsafeConfig');
        // Preserve the official SDK's own identity, never impersonate a native app.
        if (options.env.CLAUDE_CODE_ENTRYPOINT !== 'sdk-ts') fail('unsupported');
        const child = spawn(options.command, options.args, { cwd, env: { ...environment,
          CLAUDE_CODE_ENTRYPOINT: options.env.CLAUDE_CODE_ENTRYPOINT, CLAUDE_AGENT_SDK_VERSION: SDK_VERSION }, detached: true, stdio: ['pipe','pipe','pipe'] });
        children.add(child); emit({ event: 'processGroup', pid: child.pid });
        child.stderr.on('data', () => {});
        child.once('exit', () => { children.delete(child); emit({ event: 'processGroupEnded', pid: child.pid }); });
        return child;
      }
    });
  } catch (error) {
    emit({ event: 'error', code: codes.has(error?.code) ? error.code : 'unavailable' }); process.exitCode = 1;
  } finally {
    settled = true; clearTimeout(timer);
    for (const child of children) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} }
    process.stdin.destroy();
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
