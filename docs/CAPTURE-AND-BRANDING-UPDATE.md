# Capture and desktop polish

Current source-audio retention and local second-pass behaviour is documented in
[CAPTURE-REFINEMENT.md](CAPTURE-REFINEMENT.md). It supersedes earlier text-only
capture assumptions; default capture still discards audio.

- Capture-list changes are broadcast after the database transaction commits,
  including deletes. Summary retries cannot recreate a deleted capture.
- Audio modes: microphone only, system only, both sources, or no audio with a
  selected screen. Microphone-only capture starts no ScreenCaptureKit stream and
  does not request screen permission. Loading optional screen choices is explicit.
- Microphone and system audio use separate transcription sessions. New transcripts
  use `[Mikrofon]` and `[Systemaudio]`, not inferred identities. Legacy text remains
  unchanged. Microphone audio can contain several room speakers; system audio can
  contain several online speakers. Diarization is not implemented in this update.
- Capture and conversational voice protect their shared microphone; active or
  unsaved capture drafts cannot be deleted accidentally through the result view.
- The main app uses one SwiftUI `Window` scene rather than a `WindowGroup`.
- Editable dragon SVGs supply a coloured app icon and a black-only menu template.
  macOS may invert the monochrome template in dark menu bars for legibility.
  App-icon PNG sizes are rebuilt with `node scripts/build-icons.cjs` (requires
  `sharp`); the menu-bar asset retains vector representation.
- Small-size icon follow-up: simplify the menu silhouette and explicitly size
  it to 18 points. Load the bundled app icon at startup as well as declaring it
  in the bundle, and refresh only this app's Launch Services registration when
  installing. No global Dock reset or other application shortcuts are changed.
- Approved-artwork follow-up: the coloured icon now uses the approved close-up
  dragon trace, with the lowest projecting neck shard removed and the mouth
  colour boundary cleaned. `Branding/AitvarasDragon.svg` preserves the character
  as genuine vector paths; `Branding/Aitvaras.svg` adds the app-icon background.
  The menu template uses the matching solid-black outer contour with a
  transparent background, not a separate character design. Draft-background
  remnants are excluded while eye highlights are retained.

Verification uses synthetic transcript/store tests and bootstrap-free UI fixtures.
No live microphone, system audio, cloud model or external connector is exercised
automatically. Live capture still requires the user's explicit start and consent.

Verification: 346 package tests passed; Debug and optimized Release builds passed.
An isolated Launch Services check opened the main scene repeatedly and retained
exactly one main window. The microphone-only setup fixture ran without permission
requests or starting audio. The user approved installation; the Release app was
installed and reopened with a local rollback backup. Live audio transcription and
speaker separation quality still require a user-started capture test.

## Capture reliability and live feedback follow-up

The observed stop hang was in Vision screen-text recognition, before summary
inference. Capture now persists a checkpoint before framework cleanup. OCR has
a deadline; a non-cooperative request is quarantined rather than awaited or
duplicated. Late OCR, speech and device callbacks cannot affect a later session.
Buffered audio is drained before bounded speech finalization. Unverified final
words are retained with an explicit warning. Failed saving keeps a retryable
in-memory snapshot rather than claiming success or leaving inputs running.

The final transcript is saved and accessible before optional local summarization
starts as a separate tracked operation. Quit saves without starting a model;
unfinished summaries remain explicit user-retry work after restart. Existing
checkpoint text is preserved; words never received or saved cannot be recovered.

Capture settings independently select English/German, show Apple's on-device
asset readiness, offer explicit asset installation/retry, and choose local summary
or transcript only. Capture never implicitly downloads a missing speech model.
The configured local summary model is identified; cloud postprocessing and an
automatically updating model catalogue are not part of this update.

Live subtitles and bounded recent text/input levels are available in the same
companion panel, independent of panel visibility and chat expansion. Screen text
stays separate from spoken subtitles. Shared activity glass and the menu dragon
distinguish active work, recording and attention without blinking or polling.
Transcript copying/export and summary retry remain available from saved results.

Verification: 358 package tests in 35 suites; Debug and optimized Release builds;
bootstrap-free stop/save checks with stalled OCR, two audio sources, late callbacks,
storage failure and retry; isolated companion visibility/draft checks. Installed
Apple speech assets finalized a synthetic audio file without microphone, network
download or cloud invocation. Long real lectures and native glass appearance still
need a user-started recording and visual review.

The user-approved Release replacement was installed and reopened successfully;
the previous process exited without force-close. A local database and app rollback
backup was retained. Database integrity passed, and capture text, conversation,
message, memory and indexed-source counts were unchanged. Cloud/local inference
usage and pending delivery counts were unchanged; no automatic service was
enabled and no operation remained running after startup. The recovered lecture
checkpoint remains pending an explicit summary retry, not an automatic replay.
The renderer check counted zero frames in idle/hidden/occluded states and no
hidden visual tasks. This is not a whole-app battery benchmark or a substitute
for human appearance and live-lecture validation.
