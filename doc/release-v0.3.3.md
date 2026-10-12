# OneReader v0.3.3 release notes

Version: **0.3.3 (6)**. Distribution: macOS Developer Preview.
This checkout is a release candidate; publication follows protected validation
and the annotated exact-main tag. See the [delivery plan](../plan/release-v0.3.3.plan.md).

## Reader fixes

- Markdown paragraph and preamble text is fully indexed in bounded chunks.
  Library/Space/Source hits retain source/snapshot context and jump to the text.
- Existing Libraries rebuild old derived search indexes without reimporting
  sources or changing annotations, reading positions or history.
- New PDFs open on their first page; EPUBs follow native spine order. Saved
  positions and explicit navigation continue to take priority.
- macOS PDFs retain actual horizontal and vertical viewport placement after
  restart at unchanged window size/zoom, including mixed-width pages.
- iPhone Files-picker completion/cancellation is repaired. Native PDF pinch,
  zoom-in/out and fit-width controls retain live scale through position updates.
- PDF-only position publication avoids unnecessarily refreshing the whole
  reader; other formats retain their existing notification behavior.

## Evidence and compatibility

Baseline integrated dev 0aec9a2 passes 265 shared tests and its exact-head
hosted pipeline. Independent macOS acceptance verifies the actual 252-page PDF
first page, 150% zoomed two-axis restart/Space return, Markdown Library search
and visible recovery, and Paper/Dark at 1440x900 and actual 900x702. Candidate
physical-iPhone, promotion, Release and downloaded-product results are recorded
separately; baseline results are not relabeled as these later gates.

Database schema **10** invalidates derived search projections only. Adapter and
Locator schema **1**, Agent runtime schema **5**, and pinned dependencies remain
unchanged. Existing immutable source bytes, notes and progress retain identity.
No account or AI Provider is required for basic reading.

## Distribution limits

- Ad-hoc signed and Sandbox-enabled; not Developer ID signed or notarized.
- DMG/ZIP plus SHA-256 sidecars and release manifest; no signed iPhone IPA,
  TestFlight or App Store distribution in this release.
- iPad remains in the universal target, but physical iPad acceptance is deferred.
- iPhone high-refresh opt-in leaves pacing adaptive. A short native hitch was
  retained in earlier same-device performance evidence; neither a fixed 120 FPS
  nor zero intermittent hitches on arbitrary documents is claimed.
- The actual compact macOS acceptance frame is 900x702, not untested 900x650.
- Real PDF inputs, screenshots, device results and credentials are not committed.
