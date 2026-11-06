# Dragon runtime asset

`App/Resources/AitvarasDragonRuntime.glb` is the default companion character for
fresh profiles. `AvatarView` loads it first and falls back to the older
`AitvarasDragon.glb` if it is missing. Existing human-avatar preferences are
respected; choose **Companion creature** in Setup to switch.

This folder records how the asset was made and how it was checked. The approved
Blender master and the design studies behind it are not in this repository
because of their size.

## Asset

- 134,271 triangles and 69,466 pre-export mesh vertices (UV seams can add
  exported vertices), about 89% fewer triangles than the master.
- 17,670,196-byte GLB with a 2048px color atlas, a baked 2048px tangent normal
  map, smaller secondary textures and a 1024×512 eye atlas.
- Real geometry keeps the prominent shards, horns, wings and silhouette. Small
  scale relief moves to the normal map.
- Live `jawOpen`, left/right eyelid blink and four eye-look morphs.
- The seated pose and contact corrections are baked in. No Blender rig,
  constraints, collision solver or locomotion simulation runs in the app, and
  the asset has no body clips. Walking or flying would need a new export from
  the rigged master.
- The master was generated with Meshy and then refined in Blender; see
  `App/Resources/AVATAR-CREDITS.md`. Nothing calls an external service at runtime.

## Rebuild

```sh
blender --background --python scripts/build-dragon-runtime.py -- MASTER.blend OUTPUT_DIR
```

The script needs the approved master, whose SHA-256 is `source_sha256` in
`runtime-audit.json`, and it checks that the master is unchanged afterwards. It
writes the GLB and a new audit to `OUTPUT_DIR`. Inspect the result before copying
it to `App/Resources/`. The committed audit records the geometry, morph transfer
errors, texture sizes and the GLB's own SHA-256.

A rebuild gives the same triangle and vertex counts but not a byte-identical
file, so expect a different GLB hash.

## Rendering and energy policy

- Native SceneKit + GLTFKit2 with 2× antialiasing, static environment lighting,
  two shadowless lights and a simple contact-shadow image. No ray tracing, live
  reflection probes, screen-space AO, bloom or shadow-map passes.
- Visible idle shows a cached still with no continuous frame loop. Brief eyelid
  blinks wake rendering at intervals.
- Listening and thinking use finite pose-transition bursts. Speaking is capped at
  30 requested FPS.
- Hidden, minimized, occluded, app-hidden, detached, display-asleep or
  system-asleep: render flags off and visual tasks cancelled. Model-state changes
  while hidden only cache inputs.
- Visibility and sleep changes are notification-driven, not polled. App
  deactivation alone does not suspend the floating companion.

This covers avatar work only. Voice sessions and scheduled tasks are not affected.

## Check it

```sh
GLTFKIT2_FRAMEWORK=/path/to/GLTFKit2.framework \
  zsh scripts/check-avatar-renderer.sh --avatar-efficiency-check OUTPUT.json
```

This compiles the real renderer sources into a minimal host with no AI engines,
connectors, microphone, database or user preferences, runs the focused policy and
asset tests, and counts native render callbacks in each visibility state. It
briefly opens a test window. `--avatarshot OUTPUT.png` produces a preview instead.
The helper targets Apple Silicon. `GLTFKIT2_FRAMEWORK` can be left out if the
framework is at `.build/DerivedData/Build/Products/Release/`.

`renderer-check.json` is the committed result. It shows zero frames in every idle
and suspended phase, and speaking within the 30 FPS cap. Sleep is tested through
notifications, so it is not a physical sleep/wake test, and it makes no claim
about whole-app power use or battery life.
