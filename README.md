# IndicateAppleDisplay

A Core Graphics backend for the instrument scene-command IR, plus the display
discipline a panel needs before its frame may be shown.

## Migration note

This package was previously named InstrumentSceneKit. The rename changed the
package name, the product name, and the module name. The public API and the
behaviour did not change.

The package takes encoded scene bytes and produces pixels. It has no
dependency on any producer, on Rust, or on any protocol: a scene is a byte
buffer, and everything here is downstream of that. The same package serves a
tester app, an EFB, and a simulator-connected instrument window, because none
of those differ in anything it does.

## What it is frozen against

The vocabulary, not the panel set. Adding panels — a replacement PFD, a moving
map, a third-party plugin — changes nothing here: a new panel is a new producer
function emitting the same opcodes, and it arrives as a `PanelRequirements`
descriptor rather than as a case in an enum. Only a genuinely new opcode
touches this code, and the version policy already covers meeting one in the
field: unknown opcodes are counted, never fatal at the decode layer.

Text is the one thing the package refuses to guess. Glyphs come from an
injected `GlyphAtlas` — the protocol is declared here, the implementation is
supplied by the consumer, usually from the producer's own verified pack. There
is deliberately no system-font fallback: a panel layout is designed against
known metrics, and substituting a platform font changes what a reading says
while still looking plausible. That injection is also what keeps this package
free of the producer.

## Two layers

**Painting** — `SceneDecoder`, `SceneValidator`, `SceneRenderer`,
`SceneBounds`, `SceneTrace`. Decode, enforce the layer contract, paint onto a
`CGContext` or into an offscreen image. Verified against the cross-backend
conformance corpus.

**Display host** — `PanelDisplay`, `PanelHealth`, `PanelRequirements`,
`FailurePage`, `InstrumentPanelView`. What separates a painter from a display:

- **Paced by the display, not by the data.** `InstrumentPanelView` pulls a
  frame per display refresh. Repainting per arriving packet ties display work
  to link traffic and is the named anti-pattern.
- **Transactional.** A frame is painted offscreen and committed only after it
  passes the layer contract *and* the panel's own critical-layer requirement.
  Nothing partial is ever visible.
- **Latched.** Any failure covers the panel with `FailurePage` and stays
  covered until a recovery streak completes. One lucky frame never clears a
  fault, and a stale good image is never left on screen.
- **Watched.** An independent tick latches `LIVENESS` when frame advancement
  stalls, and re-arms rather than judging when its own scheduling was starved.
  Both schedulers live on the main run loop, so this catches a stalled
  producer, not a wedged UI thread; a monitor that survives the latter must
  consume `PanelHealth.snapshot` from elsewhere.
- **Diagnosable.** `DisplayReason` codes are shared with the other backends of
  this IR, not minted here. An operator reading `D-106` off a covered panel
  looks up the same code whichever backend drew it.

Unknown opcodes are where the two layers deliberately disagree. The decoder and
the layer gate count and skip, because that is the version policy the
conformance corpus pins. A display host fails the frame by default
(`UnknownOpcodePolicy.failFrame`), because painting a scene with commands it
silently dropped can bleed a layer that must never show through — a dropped
clip is invisible as a fault and visible as wrong content.

## Usage

```swift
let designFrame = CGSize(
    width: descriptor.designWidth,
    height: descriptor.designHeight
)
let requirements = PanelRequirements(
    id: descriptor.id,
    title: descriptor.title,
    criticalLayerMask: descriptor.requiredLayers,   // from the producer
    frameMin: designFrame,
    frameMax: designFrame,
    canonicalFrame: designFrame
)!

let display = PanelDisplay(
    requirements: requirements,
    producer: ClosureSceneProducer { SceneFrame(bytes: try panel.render(state), generation: gen) },
    atlas: producerGlyphAtlas
)

InstrumentPanel(display: display) { outcome in
    report = outcome.reason
}
```

Hold the `PanelDisplay` for the lifetime of the panel. Rebuilding it per state
change would dismiss a latched fault and rebuild every glyph outline.

## The conformance corpus

`Tests/IndicateAppleDisplayTests/Fixtures/scene-conformance-corpus.json` is
authored and reviewed upstream by the reference rasterizer; this repository
only ever compares against it. `ConformanceTests` pins its schema version,
corpus version, digest, and entry counts, so an upstream regeneration cannot
silently re-baseline this interpreter against a moved target.

- `scripts/sync-corpus.sh [path-to-Indicate]` — vendor the current upstream
  corpus and update its provenance record. The pinned expectations in
  `ConformanceTests.swift` still have to be updated by hand, which is the
  point: a sync leaves a diff to review.
- `scripts/check-corpus.sh` — fail on drift. It always verifies the vendored
  copy against its provenance record, and additionally compares against
  upstream `HEAD` when an Indicate checkout is available (`INDICATE_DIR`, or a
  sibling directory).

Pull-request CI runs the local half only. It verifies the vendored copy
against its provenance record and skips the upstream comparison, so a pull
request stays pinned and deterministic. The `corpus-drift` workflow runs the
full comparison on a schedule and on demand. It checks out Indicate, sets
`INDICATE_DIR`, and fails when the checkout is missing or when upstream has
regenerated the corpus. It never syncs the corpus: a drift is a diff to review
by hand with `scripts/sync-corpus.sh`.

## The backend gallery

`Examples/BackendGallery` is a small macOS executable that renders selected
corpus scenes and the display host's failure behaviour. It is a sample, not a
product: it lives outside the library, and a consumer of the library does not
depend on it.

Run it from the repository root:

```sh
swift run BackendGallery
```

The window shows one row per case: a valid scene at two output sizes, the
unknown-opcode policy both ways, a missing critical layer, a producer fault, a
liveness trip, a recovery streak, glyph-backed text with and without an atlas,
and a corpus-rejected scene. Every covered frame comes from `PanelDisplay` or
`PanelHealth`, never from a hand-drawn overlay. Each row shows the layer mask,
the unknown-opcode count, and the display reason. The header shows the IR
version, the corpus version, and the corpus digest.

The headless path exports the same cases as PNG images, writes a manifest, and
verifies every outcome against its expected reason:

```sh
swift run BackendGallery --export .build/gallery
```

It exits with a non-zero status when a case does not match, so CI can use it as
a smoke test. `scripts/ci.sh` runs it. Pass `--corpus <path>` to read a corpus
from somewhere else.

## Build and test

```sh
swift test
./scripts/ci.sh          # build, test, and the corpus guard
```

Requires Swift 6.1, iOS 17, or macOS 14.
