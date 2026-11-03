# External message trust and phishing boundary

## Security objective

External text must never acquire user authority merely because it reached an
inbox, notification feed, calendar export or configured API. Aitvaras therefore
separates two decisions:

1. **May this source be processed proactively?** This is the trusted-sender
   preference described here.
2. **May this content cause an action?** Message text always remains untrusted;
   the narrow external-message agent can only propose a new calendar event or
   reminder, and either proposal still requires explicit confirmation.

“Trusted” means **approved for quarantined processing**, not authenticated,
safe, or allowed to issue instructions.

## Harmful input sources

| Source | Attacker-controlled material | Identity available | Treatment |
|---|---|---|---|
| Apple Mail | Display name, From address, subject, body, quoted replies and URLs | Parsed From address/domain; not cryptographically verified | Unknown senders are held before model access. Approved senders use the external-message quarantine. Attachments are not read. |
| macOS notifications | App-supplied title, subtitle and body | Exact app bundle id plus visible sender label; the contact itself is not verified | Unknown app/label pairs are held. Approval is scoped to the exact pair. |
| Moodle iCal | Summary, categories, description, dates and UIDs | A service the user configured with a private feed URL | Tool-free classifier only. Payload remains untrusted. |
| Custom HTTP triggers | Remote JSON values and rendered event text | A connector manifest the user installed | Tool-free classifier only. Payload remains untrusted. |
| Web/search results | Page text, redirects and attacker URLs | User-initiated public URL | Existing public-network and size boundary; never available to an external-message turn. |
| News feeds | Headlines, summaries, image URLs and links from RSS/Atom or Google News discovery | Explicit publisher-domain catalogue, not the article text | Separate bounded tables; never Activity/Memory/RAG evidence. Topic writes are UI-only. Model output is delimited as untrusted data; read-aloud treats it as speech, not instructions. |
| User-requested Mail results | Sender, subject, body, quoted replies and URLs | Same parsed From identity as polling | Unknown content is redacted; approved results reset the turn into the external-message quarantine before the next inference. |
| RAG/calendar/other tool results | Local or synced content that can contain embedded instructions | User-initiated tool context | Marked as untrusted data in the normal agent prompt; write risks stay centrally enforced. |
| Compromised approved account | Authentic-looking mail or messages from a real contact | Same identity as a legitimate sender | Still quarantined. Approval cannot protect against account compromise or social engineering. |

## User interaction

The **Connections → Message safety → Trusted senders** screen has two lists.

- **Waiting for review** contains only source identity, app/domain, timestamps
  and a count. Message subjects and bodies are not duplicated into this table.
- **Trusted for quarantined processing** contains removable exact-address,
  exact-domain and exact notification app/label rules.

For an observed source, the user can:

- trust one exact mail address;
- trust one exact notification label within one exact app;
- trust an exact mail domain after an explicit warning; or
- dismiss the observation without trusting it.

An exact mail address can also be entered manually. Removing a rule immediately
returns future messages from that source to the held path.

### Domain rules

Domain matching is exact. `example.org` does not match `mail.example.org` and
never matches `example.org.evil.test`. Unicode domains are not normalized into
approval rules.

Domain-wide approval is disabled for shared consumer mailbox providers,
including `t-online.de`, Gmail, GMX, Web.de, Outlook, iCloud, Proton and Yahoo.
Approving `t-online.de` would approve every t-online customer, so individual
addresses are the only safe usable scope there.

## Runtime enforcement

### Unknown sender

1. The connector attaches a bounded structured source identity.
2. Intake checks the local trust database before any model call.
3. An unknown mail/notification sender is atomically recorded in Activity, the
   seen-item table and the sender-review queue.
4. It is not classified by a model, forwarded to Telegram, announced, given
   personal context, or passed into the agent loop.

An event producer that omits structured source provenance also fails closed and
cannot reach a model. This keeps a future connector from accidentally bypassing
the boundary; it must first define how its source is identified or configured.

User-requested Mail read/search tools apply the same rule: an unapproved
sender returns only an opaque message id, canonical address and “held” status,
never its subject or body. When approved mail content is returned, the rest of
that agent turn is rebuilt without Memory, RAG or conversation history, marked
externally influenced, and switched to the same hard tool allowlist and
confirmation policy. The inference that selected the Mail tool ran before it
saw any mail content; every inference that can see the result gets only the
quarantined context. This prevents a manual “read my latest mail” request from
becoming an alternative exfiltration route.

### Approved sender

Approval permits local triage, but an actionable mail enters a separate
external-message execution profile:

- no saved Memory facts or legacy memories;
- no Knowledge/RAG retrieval;
- no conversation history;
- no web, mail, file, memory, delegation, notification or existing-planning
  read tools;
- only `calendar.create_event` and `reminders.create_reminder` are advertised;
- ConnectorHub independently rejects every other external-origin tool call;
- both allowed writes always become confirmation cards, even if the normal
  autonomy whitelist would allow them.
- URL-like text is rejected from those proposals so a phishing destination
  cannot be copied into Calendar or Reminders;
- proactive local/Telegram previews strip URL-looking text and use a neutral
  sender title instead of forwarding a mail subject as a clickable alert.

This prevents the classic injection/exfiltration chain “read a malicious mail
→ search private memory → place the result in an attacker URL”.

## Why the UI does not claim verification

DMARC validates alignment between the visible From domain and an SPF- or
DKIM-authenticated identifier; comparing the visible From string alone is not
DMARC verification ([RFC 7489](https://datatracker.ietf.org/doc/html/rfc7489)).
Likewise, an `Authentication-Results` header is trustworthy only when the
consumer knows it was produced inside the receiving mail system's trust
boundary; the field has no integrity protection of its own
([RFC 8601](https://datatracker.ietf.org/doc/html/rfc8601)).

The current Apple Mail automation interface supplies the visible sender string
but does not give Aitvaras a receiver-authenticated DMARC result with a known
authentication-service boundary. Arbitrary authentication headers in message
content therefore are not parsed or trusted. BSI guidance makes the practical
consequence explicit: sender addresses and even messages from known senders can
be forged, and unsigned mail identity/content is not inherently trustworthy
([BSI mail-client guidance](https://www.bsi.bund.de/SharedDocs/Downloads/DE/BSI/Internetsicherheit/isi_mail_client_leitlinie_pdf.pdf?__blob=publicationFile&v=1)).

A future “verified sender” badge would require a trustworthy mail-provider API,
a Mail extension that exposes authenticated receiver results, or an end-to-end
signature such as S/MIME. Until then, the system deliberately says *approved*,
not *verified*.

## Phishing behavior

Trusted contacts reduce unsolicited automation; they do not replace phishing
judgment. Unexpected payment, password, account-lock or attachment requests
remain suspicious even when they appear to come from a known organization.
Aitvaras does not open links or attachments from proactive mail turns. The user
should independently navigate to a known website or contact the sender through
a known channel, not through contact details in the message. This matches
[FTC phishing guidance](https://consumer.ftc.gov/articles/how-recognize-avoid-phishing-scams)
and [BSI consumer guidance](https://www.bsi.bund.de/DE/Themen/Verbraucherinnen-und-Verbraucher/Informationen-und-Empfehlungen/Cyber-Sicherheitsempfehlungen/cyber-sicherheitsempfehlungen.html).

## Persistence and tests

Migration `v8-message-trust` adds `trustedMessageSource` and
`messageSourceObservation`. Incoming-event audit, deduplication, connector
checkpoint and observation upsert share one SQLite transaction, so neither a
phantom trust observation nor a lost source event can survive a partial write.

The automated suite covers sender parsing, ambiguous/Unicode failure-closed
behavior, exact-domain and suffix attacks, shared-provider rejection,
notification app scoping, atomic deduplication and rollback, review-queue
resolution, removal, proactive and interactive-mail context isolation, blocked
read/exfiltration tools, link rejection and confirmation-only planning writes.
