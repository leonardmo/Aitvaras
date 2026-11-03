# Activity glass and subtitles in the companion overlay

Design reference and delivery checklist. The user subsequently authorized the
near-term implementation below, without extending the larger work-hub plan.

Implemented: shared activity glass, state-coloured menu dragon, compact companion
activity, independently toggleable live subtitles/input health, and expandable
in-overlay chat with retained drafts. Hidden/minimal layouts do not mount the
avatar. Presentation is event-driven; no decorative inference or refresh loop.
Native material appearance still needs human review in the installed app.

Follow-up implemented: app-global bottom dock (default), sidebar footer or
minimized capsule, with a remembered placement menu. A hidden sidebar falls back
to the capsule without changing the saved preference. Status is no longer nested
inside section content. Glass uses slate/violet/ember gradients; active menu
artwork uses matching cached gradients, while idle remains monochrome. Transitions
are finite state-change crossfades, not repeating motion; Reduce Motion disables
them and contrast/transparency accessibility settings retain opaque fallbacks.

## 1. A distinct activity surface

The current activity panel is useful. Give it a recognizable, visually separate
place in the app rather than making operational status look like ordinary text
inside another list.

- Explore a compact, consistently positioned activity card below the main-window
  toolbar. Keep it visible across sections without moving surrounding content.
- Use a restrained liquid-glass treatment: translucent tinted material, a subtle
  coloured edge/highlight, rounded corners and a solid, readable content layer.
  The look should feel like an AI activity surface, without a constantly moving
  gradient or decorative animation implying work that is not occurring.
- Relate the palette to the approved dragon: charcoal/slate blue with warm ember
  accents. Exact colour values and opacity remain subject to visual review.
- Strong hierarchy: status symbol and plain-language headline first; current
  stage and honest progress second; provider/location and data destination as
  concise secondary labels. Elapsed time and safe controls align consistently.
- Keep concurrent operations separately inspectable. A compact summary may show
  active, waiting and attention counts, but must not cycle through messages or
  hide a recording behind an unrelated task. Expand to the existing full panel.
- Keep idle, paused, waiting, unavailable monitoring and failures visually and
  verbally distinct. Colour supplements text and symbols, never replaces them.
- Show recording/listening explicitly. Avoid exposing transcript, mail or other
  sensitive content in the compact operational summary.

## 2. Shared visual language with the menu bar

- Idle: the monochrome dragon template, legible on light and dark menu bars.
- Active work: a restrained accent-coloured dragon matching the activity card.
  Enabled but idle services alone do not count as active work.
- Explore a separate recording cue and an amber attention cue; define priority
  when states overlap, without concealing either in the expanded menu.
- Mirror the same state labels, symbols and colour meaning in the app, menu and
  minimal companion. Do not introduce a second activity-state implementation.
- Use event-driven changes only. No blinking, pulsing, status-refresh polling,
  background model calls or unnecessary rendering to sustain the effect.

## 3. Compact activity glass in the companion

- Embed a compact activity-glass card inside the existing companion overlay,
  not a separate floating window or detached buttons. Share the main app's
  material, typography, symbols and state colours at a smaller scale.
- Prioritize a short status headline, recording/input health when relevant,
  and an optional concise stage or progress line. Make additional concurrent
  work and attention items reachable without crowding the compact view.
- Reuse the existing activity detail panel for expanded information. Do not
  automatically expand or reveal the companion when activity changes.
- Work in minimal mode with the avatar disabled; no 3D rendering is required.

## 4. Optional live subtitles inside the same overlay

Lecture-testing feedback calls for a subtitle section embedded in the existing
companion, not an independent subtitle window.

- Show one or two readable lines within the overlay's single visual container,
  alongside the compact activity card. Keep controls compact and grouped; avoid
  detached controls or overlapping the avatar when it is enabled.
- Provide an explicit show/hide control for subtitles independently of the
  entire overlay. Hiding subtitles leaves the activity card and other companion
  controls available.
- Preserve the existing UI and keyboard-shortcut behaviour for showing/hiding
  the whole overlay. This behaviour is already satisfactory and should not be
  replaced or require a new shortcut.
- Keep recording/transcription, subtitle visibility and overall overlay
  visibility separate. Hiding text or the overlay must not stop capture, change
  its inputs or discard transcript data. Showing it again resumes the current
  view without duplicate processing or replaying old subtitles.
- Do not automatically reveal hidden subtitles or the hidden overlay on new
  speech. Recording status remains discoverable through the main app/menu;
  system privacy indicators and existing risk-notification rules remain intact.
- Use a bounded subtitle area so longer speech does not repeatedly resize or
  shift the entire panel. Existing companion position/size behaviour remains
  the baseline; review any necessary layout changes before implementation.
- A translucent, contrast-safe background in the same visual family as the
  activity card. Do not require the avatar or render its 3D scene.
- Distinguish provisional words from finalized phrases without jumping layout,
  repeating lines or implying unsaved text is already durable.
- Optional microphone/system-audio labels. Source labels are not speaker
  identities; do not imply diarization already exists.
- A quiet, truthful input/save-health indicator. Clicking expands recent text,
  audio levels, the selected screen/window, last screen-text capture and
  actionable input or save warnings.
- Keep OCR text out of the subtitle flow by default. It enriches the saved
  transcript and remains inspectable in the expanded view.
- Do not hide or bypass system recording indicators or the consent requirement.
  Capture scope must be explicit; avoid capturing the overlay itself.
- When hidden, stop unnecessary subtitle/UI rendering work, not the explicitly
  running capture pipeline. Display changes require no extra inference.

## 5. Chat on demand inside the companion

- Do not keep a text box permanently visible in the compact overlay. Provide a
  clear chat button instead, leaving more room for activity and optional subtitles.
- The button expands a larger chat interface directly within the same overlay:
  readable conversation history, a comfortable composer and send controls. Do
  not open a detached chat window or force navigation to the main app.
- Allow collapsing back to the compact view. Preserve the conversation and any
  unsent draft; expanding, collapsing or hiding the panel must not send a message,
  start inference or cancel an in-progress response.
- Keep compact activity/recording status discoverable while chat is expanded.
  Treat chat expansion and subtitle visibility as separate controls, and avoid
  overlaying text or controls on each other.
- Preserve the existing whole-panel UI toggle and shortcut in both layouts.
  Clamp the expanded panel to the available screen and retain a stable position
  when returning to its compact size. Apply the same glass visual language.
- Planned: discuss an ongoing tutorial/capture here, including with an explicitly
  selected frontier model, without interrupting recording. Show recording health,
  the transcript context cutoff and outbound-sharing scope. See
  [work-hub phase 2C](WORK-HUB-PLAN.md#2c-discuss-the-tutorial-while-capture-continues)
  for context, privacy and verification requirements; this is not implemented.

## 6. Verification and remaining review

- Collect lecture-test feedback: delay, missed sentences, technical terms,
  long-session reliability, input failures and checkpoint visibility.
- Review static app/menu/subtitle mockups together, including simultaneous work,
  approval waits, recording, errors, paused services and unavailable monitoring.
- Verify independent visibility combinations: companion with subtitles, companion
  without subtitles, and hidden companion while capture continues. Confirm the
  existing UI toggle and shortcut still work and never alter recording state.
- Review compact/chat-expanded layouts, including optional subtitles. Verify
  conversation/draft preservation and uninterrupted capture or model responses
  when collapsing or hiding the panel.
- Test light and dark backgrounds, Increase Contrast, Reduce Transparency,
  reduced-motion preferences and narrow window layouts. Provide an opaque
  fallback; readability takes priority over glass effects.
- Check idle/hidden energy use. Reuse existing activity events and observation;
  visual polish must not change execution, privacy or notification policies.
- Live subtitle and input-meter views are implemented. Diagram interpretation,
  speaker diarization and a new transcription backend remain outside this update.
