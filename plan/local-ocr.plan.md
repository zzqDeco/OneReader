# Local OCR

## Status

Active — implementation and acceptance pending. Tracks [Issue #26](https://github.com/zzqDeco/OneReader/issues/26).

## Branch

`feature/local-ocr`, based on `dev` at `a3c5b241d8678c806cf2f4a5d04cf21c2f909063`.

## Milestone

Next reader feature increment; no release or date commitment.

## Dependencies

Existing immutable managed snapshots, adapter capabilities, transactional search projection,
native presentations, annotations and reading-position restoration. Coordinates migration v14
with capture v11, notes v12 and translation v13. No new package dependency.

## Summary

Use Apple Vision locally to derive searchable, source-aligned text for PDF pages and individual
JPEG, PNG and HEIC images. Keep original bytes, original reader and original progress intact.
Publish immutable OCR revisions through a registered adapter, never as model-authored text.

## User Behavior

- Open the original immediately; explicitly recognize current page, a page range or the document.
- Show language, completed/failed pages, cancellation, retry and explicit interrupted-job resume.
- Mark OCR text as recognition output. Search, copy and annotate using real page/image regions.
- Keep native PDF text by default; explicit replacement applies only to selected pages.
- Never upload for recognition; optional later translation/question answering uses existing consent.

## Contracts / Migration

- `OCRJob`, `OCRRevision`, `OCRPage`, `OCRSpan` bind source, snapshot, engine, settings and geometry.
- Migration v14 stores jobs and immutable revision results; startup interrupts unfinished jobs.
- Each OCR locator carries revision and span identity, text quote and original-space rectangle.
- PDF rasterization records an invertible crop/rotation transform; images normalize EXIF orientation.
- A result becomes active only after validating its source snapshot and current job generation.
- Prior revisions remain available for old annotations and evidence. No destructive cache clearing.
- Index plan identity includes OCR revision; the existing projection swap rejects stale work.

## Implementation

1. Codable contracts, bounded resource policy, geometry and transactional revision persistence.
2. Injectable recognition engine; serial Vision worker, supported-language check, bounded decode.
3. Native image adapter and OCR adapter combining OCR pages with untouched native PDF text.
4. Cancellable durable jobs, explicit resume and source-removal/revision invalidation.
5. Native OCR controls and source-linked selectable recognized text/region overlay.
6. Integrate search, annotation, reading progress and optional Agent/translation observations.

## Test Plan

- Deterministic geometry across crop offsets and 0/90/180/270 degree rotation; <=2pt error.
- Fake-engine cancellation, stale generation/revision rejection, partial failure, restart and retry.
- Immutable revision resolution, native/OCR deduplication, evidence retention and migration.
- Corrupt/encrypted input, size/pixel/page bounds, unsupported language and no network dependency.
- Locally generated bilingual printed-image/PDF fixture: real Vision phrases, ordering and regions.
- Integrated native build plus macOS visible and physical-iPhone import/search/zoom/restore checks.
- No Simulator, production Library, automatic cloud call or release/distribution mutation.

## Acceptance Evidence

- 2026-10-13, OCR plus PDF position suite: 26 tests, two explicit real-Vision smoke skips,
  zero failures. Full macOS SwiftPM suite: 279 tests, the same two skips, zero failures.
- Physical iPhone 18 Pro Max: 19 hosted tests, zero failures. Actual Vision recognizes the
  generated English and Chinese phrases in 0.643 seconds and preserves original bytes.
  Six native overlay/image tests cover all four page rotations, nonzero crop origins,
  selection hit-testing, image coordinate inversion, decode bounds and position recovery;
  twelve existing PDF zoom tests also pass. These are hosted automated tests, not manual
  product acceptance or a frame-rate benchmark.
- Accurate revision 3 stalls on this Mac in both XCTest and an independent native AppKit
  diagnostic. Accurate revision 2 with supported CPU devices recognizes English and Chinese
  in 0.543 seconds. The production engine now pins revision 2 on macOS and revision 3 on iOS,
  and records the actual pipeline in each OCR revision. Fifteen OCR tests then passed with
  zero skips, including real mixed-PDF and bilingual-image recognition. Those real fixtures
  now run by default, including CI; no environment opt-in hides an OCR failure.
- Source-switch callback invalidation and same-image search navigation are covered by new
  regressions. The focused OCR/image/PDF suite passed 30 tests before removing smoke skips.

No automated test substitutes for visual acceptance. OCR is not yet accepted for delivery.

## Non-goals

Cloud OCR, handwriting/formula/table reconstruction promises, camera scanning, rewritten searchable
PDF export, new OCR model dependency, iPad device acceptance or release/signing rollout.

## Delivery Checklist

- [ ] Contracts and migrations validated.
- [ ] Original-aligned recognition, selection, search and annotations implemented.
- [ ] Cancellation, restart and revision tests pass.
- [ ] Real local recognition and native acceptance recorded.
- [ ] Current-state documentation and indexes updated.
- [ ] Native validation and Sol max review pass before integration approval.
