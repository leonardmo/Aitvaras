// Offline only: synthetic SDK, no Claude process, credentials, account calls or network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { runBridge, optionsFor, cleanEnvironment, subscriptionAccount, verifiedSubscriptionAccount, accountNamespace, namespace, CLI_VERSION, ensureSecureCredentialStorage } from '../Sources/AitvarasConnectors/Resources/claude-interactive.mjs';

const account = { apiProvider: 'firstParty', tokenSource: 'claude.ai', apiKeySource: 'none', subscriptionType: 'max', email: 'learner@example.invalid', organization: 'synthetic-org' };
const base = namespace('separate', '/tmp/synthetic/claude-account');
const request = { operation: 'run', accountMode: 'separate', profileNamespace: base, expectedNamespace: accountNamespace(base, account),
  context: 'Synthetic context', model: 'synthetic-model', prompt: 'Synthetic prompt', projectRootCount: 0 };
const responseID = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';

function fixture(overrides = {}) {
  const events = [], received = [], checks = [], ownership = [];
  let queryOptions, promptRead;
  const sdk = { query({ prompt, options }) {
    queryOptions = options;
    promptRead = prompt[Symbol.asyncIterator]().next().then(value => { if (!value.done) received.push(value.value); return value; });
    return {
      initializationResult: async () => ({ claude_code_version: overrides.version ?? CLI_VERSION }),
      accountInfo: async () => overrides.account ?? account,
      supportedModels: async () => [{ value: 'synthetic-model', displayName: 'Synthetic Model', supportedEffortLevels: ['low','high'] }],
      close: () => {}, interrupt: async () => {},
      async *[Symbol.asyncIterator]() {
        await promptRead;
        if (overrides.disconnect) throw new Error('synthetic disconnect');
        const session_id = options.sessionId ?? options.resume;
        if (overrides.messages) { for (const message of overrides.messages) yield { ...message, session_id, uuid: responseID }; return; }
        yield { type: 'stream_event', uuid: responseID, session_id,
          event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Synthetic answer' } } };
        yield { type: 'result', uuid: responseID, session_id, subtype: 'success', usage: { input_tokens: 10, output_tokens: 3 } };
      }
    };
  } };
  const io = { emit: frame => events.push(frame), stopped: () => !!overrides.stopped, setInterrupt: () => {},
    request: async (frame, command, id) => {
      events.push(frame); checks.push({ command, received: received.length });
      if (overrides.rejectAck === command) throw Object.assign(new Error('synthetic persistence failure'), { code: 'unavailable' });
      return { command, id };
    }
  };
  const dependencies = { environment: cleanEnvironment('/tmp/synthetic', '/tmp/synthetic/claude-account'), cwd: '/tmp/synthetic/working', spawn: () => { throw new Error('must not spawn'); },
    authenticationStatus: async () => overrides.authStatus ?? { loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty',
      subscriptionType: 'max', email: (overrides.account ?? account).email, orgId: 'synthetic-org', orgName: 'Synthetic Organization' },
    recordOwnership: async (id, account) => ownership.push({ id, account }),
    verifyOwnership: async () => { if (overrides.unowned) throw Object.assign(new Error(), { code: 'ownership' }); }
  };
  return { sdk, io, dependencies, events, received, checks, ownership, options: () => queryOptions };
}

test('status initializes official metadata without supplying any prompt', async () => {
  const f = fixture(); await runBridge({ ...request, operation: 'status' }, f.sdk, f.io, f.dependencies);
  assert.equal(f.received.length, 0);
  assert.equal(f.events[0].event, 'result');
  assert.equal(f.events[0].result.authenticated, true);
  assert.equal(f.events[0].result.profileNamespace, request.expectedNamespace);
  assert.equal(f.events[0].result.usageWindows, null);
  assert.equal(f.options().persistSession, false);
});

test('prompt awaits both durable barriers; actual SDK UUID acknowledges delivery', async () => {
  const f = fixture(); await runBridge(request, f.sdk, f.io, f.dependencies);
  assert.deepEqual(f.checks, [{ command: 'ackSession', received: 0 }, { command: 'ackDelivery', received: 0 }]);
  assert.equal(f.received.length, 1);
  assert.equal(f.received[0].message.content, request.prompt);
  assert.equal(f.events.find(e => e.event === 'turnStarted').id, responseID);
  assert.notEqual(f.events.find(e => e.event === 'deliveryAttempt').id, responseID);
  assert.equal(f.ownership[0].account, request.expectedNamespace);
  assert.deepEqual(f.events.map(e => e.event), ['sessionCreated','deliveryAttempt','turnStarted','textDelta','completed','result']);
});

for (const barrier of ['ackSession','ackDelivery']) test(`failed ${barrier} persistence prevents delivery`, async () => {
  const f = fixture({ rejectAck: barrier }); await assert.rejects(runBridge(request, f.sdk, f.io, f.dependencies));
  assert.equal(f.received.length, 0); assert.equal(f.events.some(e => e.event === 'turnStarted'), false);
});

test('disconnect after release supplies no fabricated acknowledgement or replay', async () => {
  const f = fixture({ disconnect: true }); await assert.rejects(runBridge(request, f.sdk, f.io, f.dependencies));
  assert.equal(f.received.length, 1);
  assert.equal(f.events.some(e => ['turnStarted','completed'].includes(e.event)), false);
});

test('same-profile account drift fails before any delivery barrier', async () => {
  const f = fixture({ account: { ...account, email: 'different@example.invalid' } });
  await assert.rejects(runBridge(request, f.sdk, f.io, f.dependencies), { code: 'ownership' });
  assert.equal(f.received.length, 0); assert.equal(f.events.length, 0);
});

test('unowned native history never reaches query/resume', async () => {
  const f = fixture({ unowned: true });
  await assert.rejects(runBridge({ ...request, sessionID: responseID }, f.sdk, f.io, f.dependencies), { code: 'ownership' });
  assert.equal(f.options(), undefined); assert.equal(f.received.length, 0);
});

test('CLI version and explicit model/effort are fail-closed', async () => {
  const f = fixture({ version: '0.0.0' });
  await assert.rejects(runBridge(request, f.sdk, f.io, f.dependencies), { code: 'unsupported' });
  const g = fixture(); await assert.rejects(runBridge({ ...request, model: 'other' }, g.sdk, g.io, g.dependencies), { code: 'modelUnavailable' });
  const h = fixture(); await assert.rejects(runBridge({ ...request, effort: 'max' }, h.sdk, h.io, h.dependencies), { code: 'modelUnavailable' });
  assert.equal(f.received.length + g.received.length + h.received.length, 0);
});

test('only official subscription credential source is accepted, not API or injected OAuth', async () => {
  assert.equal(subscriptionAccount(account), true);
  for (const value of [{ ...account, tokenSource: 'CLAUDE_CODE_OAUTH_TOKEN' }, { ...account, apiKeySource: 'ANTHROPIC_API_KEY' },
    { ...account, apiProvider: 'bedrock' }, { ...account, subscriptionType: undefined }]) {
    assert.equal(subscriptionAccount(value), false);
    const f = fixture({ account: value });
    await assert.rejects(runBridge(request, f.sdk, f.io, f.dependencies), { code: 'signInRequired' });
    assert.equal(f.received.length, 0);
  }
});

test('real pinned SDK account shape accepts Claude Pro only with matching official subscription status', async () => {
  const sdkAccount = { apiProvider: 'firstParty', subscriptionType: 'Claude Pro',
    email: 'learner@example.invalid', organization: 'Synthetic Organization' };
  const authStatus = { loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty', subscriptionType: 'pro',
    email: sdkAccount.email, orgId: 'synthetic-org', orgName: sdkAccount.organization };
  assert.equal(verifiedSubscriptionAccount(sdkAccount, authStatus)?.subscriptionType, 'pro');
  const f = fixture({ account: sdkAccount, authStatus });
  await runBridge({ ...request, operation: 'status' }, f.sdk, f.io, f.dependencies);
  assert.equal(f.events[0].result.authenticated, true);
  assert.equal(f.received.length, 0);
  for (const changed of [{ ...authStatus, authMethod: 'api_key' }, { ...authStatus, loggedIn: false },
    { ...authStatus, email: 'other@example.invalid' }, { ...authStatus, orgName: 'Other Organization' },
    { ...authStatus, subscriptionType: 'max' }, { ...authStatus, apiProvider: 'bedrock' }]) {
    assert.equal(verifiedSubscriptionAccount(sdkAccount, changed), null);
  }
  assert.equal(verifiedSubscriptionAccount({ ...sdkAccount, tokenSource: 'injected-token' }, authStatus), null);
  assert.equal(verifiedSubscriptionAccount({ ...sdkAccount, apiKeySource: 'ANTHROPIC_API_KEY' }, authStatus), null);
});

test('configuration never inherits keys, alternate auth, endpoints, native hooks/tools/MCP', () => {
  const env = cleanEnvironment('/tmp/synthetic', '/tmp/synthetic/separate', 'shared');
  assert.equal(env.CLAUDE_CONFIG_DIR, undefined); // default Keychain, no path suffix
  for (const key of ['ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','CLAUDE_SECURESTORAGE_CONFIG_DIR','ANTHROPIC_BASE_URL','NODE_OPTIONS','HTTP_PROXY']) assert.equal(env[key], undefined);
  assert.equal(cleanEnvironment('/tmp/synthetic', '/tmp/synthetic/separate', 'separate').CLAUDE_CONFIG_DIR, '/tmp/synthetic/separate');
  const options = optionsFor(request, env, '/tmp/synthetic/working');
  assert.deepEqual(options.tools, []); assert.deepEqual(options.settingSources, []); assert.deepEqual(options.skills, []);
  assert.deepEqual(options.plugins, []); assert.deepEqual(options.hooks, {}); assert.equal(options.strictMcpConfig, true);
  assert.equal(options.settings.disableAllHooks, true); assert.equal(options.permissionMode, 'dontAsk');
  assert.equal(options.managedSettings.disableAllHooks, true);
});

test('plaintext credential fallback is refused from metadata only, never opened', async () => {
  const paths = [];
  await assert.rejects(ensureSecureCredentialStorage('/tmp/synthetic', async path => { paths.push(path); return { isFile: () => true }; }), { code: 'insecureCredentials' });
  assert.deepEqual(paths, ['/tmp/synthetic/.credentials.json']);
  await ensureSecureCredentialStorage('/tmp/synthetic', async () => { throw Object.assign(new Error(), { code: 'ENOENT' }); });
  await assert.rejects(ensureSecureCredentialStorage('/tmp/synthetic', async () => { throw Object.assign(new Error(), { code: 'EACCES' }); }), { code: 'insecureCredentials' });
});

test('assistant-only and result-only text work without stream events', async () => {
  for (const messages of [
    [{ type: 'assistant', message: { content: [{ type: 'text', text: 'Synthetic final' }] } }, { type: 'result', subtype: 'success', result: 'Synthetic final' }],
    [{ type: 'result', subtype: 'success', result: 'Synthetic final' }]
  ]) {
    const f = fixture({ messages }); await runBridge(request, f.sdk, f.io, f.dependencies);
    assert.equal(f.events.filter(e => e.event === 'textDelta').map(e => e.text).join(''), 'Synthetic final');
    assert.equal(f.events.find(e => e.event === 'completed').state, 'completed');
  }
});

test('stream plus assistant and result text emits only missing suffix', async () => {
  const f = fixture({ messages: [
    { type: 'stream_event', event: { type: 'content_block_delta', delta: { type: 'text_delta', text: 'Synthetic ' } } },
    { type: 'assistant', message: { content: [{ type: 'text', text: 'Synthetic final' }, { type: 'thinking', thinking: 'not output' }] } },
    { type: 'result', subtype: 'success', result: 'Synthetic final' }
  ] });
  await runBridge(request, f.sdk, f.io, f.dependencies);
  assert.deepEqual(f.events.filter(e => e.event === 'textDelta').map(e => e.text), ['Synthetic ', 'final']);
});

test('empty success is a known no-answer failure, not a successful empty answer', async () => {
  const f = fixture({ messages: [{ type: 'result', subtype: 'success', result: '' }] });
  await runBridge(request, f.sdk, f.io, f.dependencies);
  assert.equal(f.events.find(e => e.event === 'completed').state, 'failed');
  assert.equal(f.events.some(e => e.event === 'textDelta'), false);
});

test('SDK authentication error and success-shaped error result are failed, never assistant answers', async () => {
  const f = fixture({ messages: [
    { type: 'assistant', error: 'authentication_failed', message: { content: [{ type: 'text', text: 'SYNTHETIC_AUTH_ERROR_NOT_A_REPLY' }] } },
    { type: 'result', subtype: 'success', is_error: true, api_error_status: 401, result: 'SYNTHETIC_AUTH_ERROR_NOT_A_REPLY' }
  ] });
  await runBridge(request, f.sdk, f.io, f.dependencies);
  assert.equal(f.events.some(e => ['textDelta', 'assistantMessage'].includes(e.event)), false);
  assert.equal(f.events.find(e => e.event === 'providerFailure').code, 'authenticationRequired');
  assert.equal(f.events.find(e => e.event === 'completed').state, 'failed');
  assert.equal(f.received.length, 1);
});

test('result-only API error is never a completed answer, without interpreting prose', async () => {
  const f = fixture({ messages: [{ type: 'result', subtype: 'success', is_error: true, result: 'Synthetic error text' }] });
  await runBridge(request, f.sdk, f.io, f.dependencies);
  assert.equal(f.events.some(e => e.event === 'textDelta'), false);
  assert.equal(f.events.find(e => e.event === 'completed').state, 'failed');
  assert.equal(f.events.find(e => e.event === 'providerFailure').code, 'providerRejected');
});

test('owned history refresh is prompt-free, account-bound and preserves exact message identities', async () => {
  const f = fixture();
  const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const messageID = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
  f.sdk.getSessionInfo = async () => ({ sessionId: id, cwd: f.dependencies.cwd, lastModified: 10, fileSize: 100 });
  f.sdk.getSessionMessages = async () => [{ uuid: messageID, session_id: id, type: 'assistant',
    message: { content: [{ type: 'text', text: 'Canonical 🐉 reply' }, { type: 'thinking', thinking: 'excluded' }] } }];
  await runBridge({ ...request, operation: 'history', sessionID: id }, f.sdk, f.io, f.dependencies);
  assert.equal(f.received.length, 0);
  assert.equal(f.options().persistSession, false);
  assert.equal(f.options().resume, undefined);
  assert.equal(f.events.find(e => e.event === 'history').snapshot.profileNamespace, request.expectedNamespace);
  assert.deepEqual(f.events.filter(e => e.event === 'historyMessage'), [
    { event: 'historyMessage', id: messageID, role: 'assistant', text: 'Canonical 🐉 reply', append: false }
  ]);
  assert.equal(f.events.some(e => ['deliveryAttempt', 'turnStarted', 'completed'].includes(e.event)), false);
});

test('history rejects concurrent changes and mismatched ownership without publishing a snapshot', async () => {
  for (const changed of [false, true]) {
    const f = fixture({ unowned: !changed });
    const id = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
    let version = 0;
    f.sdk.getSessionInfo = async () => ({ sessionId: id, cwd: f.dependencies.cwd, lastModified: ++version, fileSize: 100 });
    f.sdk.getSessionMessages = async () => [];
    await assert.rejects(runBridge({ ...request, operation: 'history', sessionID: id }, f.sdk, f.io, f.dependencies),
      { code: changed ? 'busy' : 'ownership' });
    assert.equal(f.received.length, 0);
    assert.equal(f.events.length, 0);
  }
});
