# Local capture refinement and source retention

## Workflow

1. Apple Speech supplies live German/English captions; screen OCR remains a
   separate text source. Video frames are never saved.
2. Capture setup and Settings → Capture & transcription offer **Discard audio**
   (default), **Keep for 7 days**, or **Keep until manually deleted**. Enabling
   retention clears the consent checkbox in setup, so the changed scope must be
   acknowledged. The active Capture page identifies local audio saving.
3. Retained microphone/system audio are separate native-rate PCM16 CAF files.
   This is uncompressed audio, not a bit-exact copy of floating-point input.
   A mono 48 kHz source uses roughly 0.35 GB/hour; stereo doubles that.
4. Open a saved capture → **Source audio & improved transcription**. Select
   language/model and explicitly start the second pass. Missing model assets are
   downloaded only through a user action, never by the inference loader.
5. Read, copy or export the refined version. It never replaces the original live
   transcript or its summary. Refined Markdown export includes original screen
   text in a clearly identified section. There is no automatic refined-summary
   pipeline or cloud capture processing in this update.

## Model choice

- **Qwen3-ASR 1.7B, 8-bit** is the quality-first candidate for multilingual
  lectures. The publisher reports strong multilingual results, including German
  and English support; benchmarks do not guarantee accuracy on distant-room audio
  or technical course vocabulary. [Publisher model card](https://huggingface.co/Qwen/Qwen3-ASR-1.7B).
- **Whisper large-v3-turbo, FP16** is the faster alternative. Both models run
  through a revision-pinned native Apple-Silicon MLX speech implementation.
  [Whisper model](https://huggingface.co/openai/whisper-large-v3-turbo),
  [native implementation](https://github.com/Blaizzy/mlx-audio-swift).
- Model catalogue revisions and required file sizes are pinned in
  `CaptureRefinementModel`; downloads are approximately 2.47 GB and 1.62 GB.
  Speech weights live under the model directory's `Transcription` subfolder,
  so they cannot appear as chat-model choices.
- Processing uses bounded 30-second audio windows and mixes stereo into mono
  16 kHz without dropping a second-channel speaker. Timestamps identify source
  windows, not word-level forced alignment. Input labels are not diarization.
- Stop remains **requested** until native recognition returns from its current
  window. No detached inference is allowed to outlive an acknowledged stop.
  Models are released after each pass; no warmup or idle inference is scheduled.
  New chat/voice/capture and automatic work defer while the second pass runs.

## Privacy, storage and recovery

- Capture defaults and older profiles remain audio-discarding. The live speech
  recognizer itself never writes audio. Only the separately consented recorder
  can persist source files. No capture audio is uploaded to a provider.
- Archives are profile-scoped, UUID-named, owner-only (directory 0700/files0600)
  and excluded from automatic system backups. They are not separately encrypted;
  the Mac's device encryption and user-account security still matter.
- The recorder has a bounded queue; disk work stays off the UI/audio thread.
  Overflow, upstream gaps, changed formats, startup failure and stop timeouts
  cannot be labelled a complete recording. A failed archive does not silently
  stop or delete the independent live transcript.
- Atomic manifests/checkpoints describe sources, offsets, frame counts and typed
  failure state, without transcript content or personal paths. Crash leftovers
  stay visibly incomplete and can be exported for recovery, not silently refined
  as complete audio. Settings → **Manage retained audio** includes orphan archives
  from interrupted or failed startups.
- Seven-day expiry starts at capture start. Cleanup runs on app opening or an
  audio-storage view visit, not while the app is closed. Active recording/read
  leases block deletion. Unknown files and unsafe links are preserved rather
  than recursively removed. Exported copies have independent retention.
- Deleting source audio preserves text versions. Deleting a whole saved capture
  removes its recognized app-owned source and candidate artifacts before deleting
  the text record; errors are surfaced. Exported copies are never touched.
- Older captures that did not retain audio cannot be retrospectively refined.

## Verification

386 package tests pass, including archive permissions, default-off persistence,
partial CAF reopening, frame counts, source offsets, expiry/leases, unsafe paths,
upstream-gap handling, concurrent audio producers, stereo downmix, candidate
separation/deletion and OCR export.
Debug and optimized Release app builds pass. Bootstrap-free app checks exercise
retained two-source capture, transcript saving, explicit deletion and discard mode.

Both native models successfully processed small synthetic English and German
recordings. The German check retained two separate sources and their offsets.
The Release two-source German check also passed with all network access denied.
These are functional checks, not a representative lecture-accuracy or battery
benchmark. No real microphone, lecture, account or cloud provider was used.

The status dock supports bottom/sidebar/minimized placements. Cached icon checks
confirm multicolour gradients preserve transparent silhouettes. Native glass
screenshots can fail to flatten backdrop materials; installed-app appearance and
long real-lecture behaviour still require supervised human review.

The user-approved Release update was installed and reopened successfully. A local
app/database rollback backup was retained. Database integrity and pre/post-upgrade
capture-text, message, memory and source counts matched; cloud/local usage counts
were unchanged. Startup completed with no running operation or newly enabled
automatic service. A settled idle CPU sample was quiet; this is not a battery
benchmark. No source-audio retention choice was enabled by installation.
