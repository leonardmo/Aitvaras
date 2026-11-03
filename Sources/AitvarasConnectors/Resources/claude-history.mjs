// Read-only bridge. These are the only provider APIs this adapter calls.
// No query, resume, model invocation, transcript parsing, or provider mutations.
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

export const SDK_VERSION = '0.3.306';
export const PAGE_SIZE = 50;
export const MAX_OFFSET = 1_000_000;
const MAX_OUTPUT_BYTES = 900_000;
const coverage = 'Local Claude Code history exposed by the official SDK (including locally stored desktop sessions); not claude.ai cloud projects. Archive status, live activity and fork ancestry are not exposed. Text only; tool calls/results, thinking, attachments, system events and subagent branches are omitted. Pagination is not a frozen snapshot.';
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const codes = new Set(['missingSDK', 'unsupported', 'invalidRequest', 'unsupportedArchive', 'notFound', 'malformedData', 'pageOverflow', 'outputTooLarge', 'readFailed']);

function fail(code) { throw Object.assign(new Error(code), { code }); }
function identifier(value) {
  if (typeof value !== 'string' || !uuid.test(value)) fail('malformedData');
  return value;
}
function session(info) {
  if (!info || typeof info !== 'object' || typeof info.summary !== 'string'
      || !Number.isFinite(info.lastModified) || info.lastModified < 0
      || (info.cwd !== undefined && typeof info.cwd !== 'string')
      || (info.customTitle !== undefined && typeof info.customTitle !== 'string')) fail('malformedData');
  return {
    provider: 'claude', hostID: 'local', externalID: identifier(info.sessionId),
    title: info.customTitle || info.summary || 'Untitled Claude Code session',
    directory: info.cwd ?? null, updatedAt: info.lastModified,
    parentExternalID: null, archived: null, activity: 'Unknown'
  };
}
function nextCursor(offset, count) {
  if (count < PAGE_SIZE) return null;
  if (offset + count > MAX_OFFSET) fail('pageOverflow');
  return String(offset + count);
}

// Exported for synthetic unit tests; injected SDKs never ship in app execution.
export async function handleRequest(request, sdk, version = SDK_VERSION) {
  if (!request || typeof request !== 'object'
      || !['capabilities', 'list', 'read'].includes(request.operation)) fail('invalidRequest');
  if (version !== SDK_VERSION || !['listSessions', 'getSessionInfo', 'getSessionMessages'].every(name => typeof sdk[name] === 'function')) fail('unsupported');
  if (request.operation === 'capabilities') {
    return { provider: 'claude', state: 'ready', version, detail: coverage };
  }
  const offset = request.offset ?? 0;
  if (!Number.isSafeInteger(offset) || offset < 0 || offset > MAX_OFFSET) fail('invalidRequest');
  if (request.operation === 'list') {
    if (request.archived === true) fail('unsupportedArchive');
    const rows = await sdk.listSessions({ limit: PAGE_SIZE, offset });
    if (!Array.isArray(rows) || rows.length > PAGE_SIZE) fail('malformedData');
    return { sessions: rows.map(session), nextCursor: nextCursor(offset, rows.length), coverage };
  }
  if (typeof request.id !== 'string' || !uuid.test(request.id)
      || (request.directory != null && (typeof request.directory !== 'string' || !request.directory.startsWith('/') || request.directory.includes('\0')))) fail('invalidRequest');
  const options = request.directory == null ? {} : { dir: request.directory };
  const info = await sdk.getSessionInfo(request.id, options);
  if (info === undefined) fail('notFound');
  const summary = session(info);
  if (summary.externalID !== request.id) fail('malformedData');
  const rows = await sdk.getSessionMessages(request.id, { ...options, limit: PAGE_SIZE, offset, includeSystemMessages: false });
  if (!Array.isArray(rows) || rows.length > PAGE_SIZE) fail('malformedData');
  const seen = new Set();
  const messages = [];
  let omitted = 0;
  for (const row of rows) {
    if (!row || typeof row !== 'object' || !['user', 'assistant', 'system'].includes(row.type)
        || row.session_id !== request.id) fail('malformedData');
    const id = identifier(row.uuid);
    if (seen.has(id)) fail('malformedData');
    seen.add(id);
    if (row.type === 'system' || row.parent_tool_use_id != null || row.parent_agent_id != null) { omitted++; continue; }
    const content = row.message && typeof row.message === 'object' ? row.message.content : null;
    let text = '';
    if (typeof content === 'string') text = content;
    else if (Array.isArray(content)) text = content.filter(block => block && block.type === 'text' && typeof block.text === 'string').map(block => block.text).join('\n');
    if (!text.trim()) { omitted++; continue; }
    messages.push({ externalID: id, role: row.type, text });
  }
  return { session: summary, messages, nextCursor: nextCursor(offset, rows.length), direction: 'newer', coverage: `${coverage} ${omitted} non-text or non-main-conversation messages omitted on this page.` };
}

async function loadSDK(directory) {
  if (typeof directory !== 'string' || !directory.startsWith('/')) fail('invalidRequest');
  const root = resolve(directory, 'node_modules/@anthropic-ai/claude-agent-sdk');
  let manifest;
  try { manifest = JSON.parse(await readFile(resolve(root, 'package.json'), 'utf8')); }
  catch { fail('missingSDK'); }
  if (manifest.name !== '@anthropic-ai/claude-agent-sdk' || manifest.version !== SDK_VERSION) fail('unsupported');
  try { return { sdk: await import(pathToFileURL(resolve(root, 'sdk.mjs')).href), version: manifest.version }; }
  catch { fail('unsupported'); }
}

export async function main() {
  let response;
  try {
    let input = '';
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input) > 32_768) fail('invalidRequest');
    }
    let request;
    try { request = JSON.parse(input); } catch { fail('invalidRequest'); }
    const { sdk, version } = await loadSDK(request?.sdkDirectory);
    response = { ok: true, result: await handleRequest(request, sdk, version) };
    if (Buffer.byteLength(JSON.stringify(response)) > MAX_OUTPUT_BYTES) fail('outputTooLarge');
  } catch (error) {
    response = { ok: false, error: codes.has(error?.code) ? error.code : 'readFailed' };
  }
  process.stdout.write(JSON.stringify(response));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) await main();
