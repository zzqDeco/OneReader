# Apple Multiplatform Reader

Status: Active

Branch: `feature/apple-multiplatform-reader`

Milestone: `v0.3.0`

Dependencies: [All-in-One Reader v1](all-in-one-reader-v1.plan.md)

## Summary

Extend the native macOS reader into one Apple-platform repository that also
builds first-class iPhone and iPad applications. The Library, immutable Source
model, adapters, Reading Agent, annotations, progress, and evidence contracts
remain shared. Platform shells own navigation adaptation, import entry points,
native presentation bridges, lifecycle, and entitlements.

The same OneReader mark ships on macOS, iOS, and iPadOS. The icon depicts an
open layered book and a warm central reading path that also suggests the digit
one; it contains no text and remains legible at notification and Settings sizes.

## User Behavior

- Open the same empty Library-first product on Mac, iPhone, or iPad without a
  format picker or chat-first landing screen.
- Import one or more files or folders with the system document picker, paste a
  web or public GitHub URL, and receive a deterministic readable surface before
  optional Agent work finishes.
- Use a compact drill-down stack on iPhone and an adaptive sidebar/content/
  inspector workspace on iPad and Mac.
- Read, search, annotate, resume progress, inspect evidence, and use the single
  Reading Agent on every supported platform subject to adapter capabilities.
- Receive documents through Open In on iOS/iPadOS. Drag and drop remains
  available where the device and window configuration support it.

## Contracts/Migration

- Keep one `Source`, `SourceSnapshot`, `Locator`, adapter, graph, plan,
  annotation, progress, Provider, and Agent runtime contract across platforms.
- Store each installation in its sandbox Application Support directory. This
  milestone does not imply iCloud or cross-device synchronization.
- Copy security-scoped imports into managed storage while access is active;
  persistent source authorization is best-effort and never required to read an
  already managed Snapshot.
- Preserve the existing macOS database and schema in place. Adding an iOS app
  must not fork schema versions or reinterpret existing Locators.
- Expose unsupported platform capabilities honestly: Quick Look and selection
  controls remain gated by the active Presentation capability set.

## Implementation

- Add iOS and iPadOS 26.1 to the package platform contract and generate a
  checked-in Xcode project from `project.yml` with native macOS and universal
  iOS application targets sharing the same sources and locked dependencies.
- Isolate AppKit/UIKit differences behind narrow conditional bridges for open
  panels, pasteboard, external links, native text, PDFKit, WebKit, Quick Look,
  colors, and window-only commands.
- Adapt the root NavigationSplitView by horizontal size class: iPhone presents
  Library, Space navigation, reader, and Inspector as a drill-down flow; iPad
  and Mac preserve content-first split navigation with a collapsible Inspector.
- Use SwiftUI `fileImporter` on iOS/iPadOS and retain `NSOpenPanel` on macOS.
  Access selected security-scoped URLs only for the duration required to copy
  them into the managed Library.
- Add platform entitlements and document type declarations without broad file,
  network-server, scripting, or model-controlled write authority.
- Add a vector-like 1024 px master icon, deterministic icon-generation script,
  and complete macOS plus universal iOS AppIcon asset catalogs.
- Extend local and hosted validation with Xcode project drift checks and an
  unsigned iOS Simulator build while preserving the authoritative SwiftPM test,
  release build, macOS Sandbox package, codesign, and entitlement gates.

## Test Plan

- Run every existing domain, persistence, adapter, Provider, runtime, and reader
  state test unchanged to prove contract sharing.
- Add tests for platform-neutral URL import routing and security-scope lifetime
  coordination, compact navigation state, capability gating, and shared icon/
  project metadata validation.
- Build the universal iOS target for an available iPhone Simulator destination
  with signing disabled and build the macOS target/package in Release mode.
- Exercise generated PDF, EPUB, HTML, Markdown, directory, and unknown-file
  fixtures on iPhone and iPad simulators; keep real books and repositories local.
- Verify icon appearance at 16, 32, 60, 76, 128, 256, 512, and 1024 px, in light
  and dark home-screen contexts, without clipped detail or embedded text.

## Acceptance Evidence

Record exact commits, dependency-lock and Xcode-project digests, test totals,
Release build results, simulator device/OS, macOS package entitlement output,
screenshots for compact iPhone and regular iPad layouts, and Sol max reviewer
conclusion. Historical green evidence is not accepted as proof for the current
head.

## Non-goals

iCloud or CloudKit sync, accounts, collaboration, Catalyst, visionOS, watchOS,
App Store Connect upload, notarization, TestFlight, private Git credentials,
background source refresh, OCR, third-party adapters, or a mobile-only schema
or Agent runtime.

## Delivery Checklist

- [ ] Shared contracts compile for macOS, iOS, and iPadOS
- [ ] Native platform shells and import entry points are implemented
- [ ] Reader presentations and adaptive navigation are functional
- [ ] App icon assets are generated and integrated for all targets
- [ ] Focused tests and unified validation pass at exact head
- [ ] iPhone and iPad simulator acceptance is recorded
- [ ] Current-state and source docs are synchronized
- [ ] Sol max review conclusion is accepted
- [ ] Branch is merged into `dev`
