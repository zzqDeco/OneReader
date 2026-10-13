# Local OCR

The OCR feature derives text locally with Apple Vision. It never changes a managed Source,
Snapshot digest, original PDF/image or existing reading-position anchor. Supported inputs are
PDF and single JPEG, PNG or HEIC images. The UI offers Chinese/English or English printed-text
recognition; unsupported system languages produce an explicit failure, not a cloud fallback.
The engine revision is pinned and recorded per result: accurate revision 2 on macOS and
accurate revision 3 on iOS. On the validated macOS 27 host, revision 3 stalls even in a
standalone native diagnostic; revision 2 recognizes the same Chinese/English fixture.
This is a deliberate local compatibility path, not a switch to Latin-only fast recognition.
Recognition currently operates on standalone imported PDF/image Sources. Repository or folder
children may be imported as a separate Source before recognition; the UI does not advertise
an OCR action that would confuse multiple child files with one snapshot's page numbers.

## Evidence and jobs

Each job binds a Source/Snapshot and selected pages. Recognition uses supported local CPU
devices, is serial, cancellable and bounded to 45 seconds of waiting per page. A stalled
framework call cannot keep the UI waiting indefinitely or create extra workers. Recognition is
bounded to 1,000 pages per job, a 2,400-pixel raster edge and a 100-million-pixel image input.
There must be at least 2 GiB available capacity. An immutable revision may contain at most
32 MiB of encoded results. A malformed or unrecognized page is reported as failed rather than
counted as recognized. Native PDF text is preferred unless the user explicitly replaces it.

Completed page records commit independently. Cancellation publishes only validated completed
pages; restart marks unfinished jobs interrupted, and resume is explicit. Publication checks
the latest Source Snapshot and active job. A new job supersedes older workers.

`onereader.ocr` is a registered read/search/index adapter layered over the native PDF/image
presentation. OCR Locators bind the immutable revision, page, span, exact quote and original
rectangle. PDF rectangles use unrotated original page coordinates, derived by inverting the
actual raster transform including crop origin and rotation. Images use EXIF-normalized unit
coordinates. Span geometry and quote cannot be replaced by a model-generated guess.

## Reading and indexing

The native PDF keeps its own scroll and zoom behavior. Explicit OCR-selection mode adds
clickable recognized-line regions on the original page; the recognition panel provides
selectable text, copy, source jump and highlight actions. Image reading uses native scrolling
and magnification. Image/PDF progress remains attached to the original document, not OCR text.

Search uses OCR only on processed pages and native PDF text elsewhere, avoiding duplicate
layers. An OCR revision change invalidates the active adapter projection in the publication
transaction. The new deterministic plan includes the OCR revision in its identity, preventing
late old-plan indexing from committing mixed evidence.

Old OCR revisions are retained; changing recognition settings does not rewrite annotations.
There is no automatic destructive OCR cache eviction in this increment. Source refresh cannot
silently relocate OCR to a new Snapshot. Optional Agent/translation reads still pass through the
existing provider disclosure and evidence validation.

## Limits and acceptance

Recognition is not a guarantee for handwriting, formulas, tables or complex column ordering.
Line boxes and confidence are exposed so users can verify the original. No searchable-PDF
export, camera scanning or cloud OCR is included.

Automated and native acceptance is tracked in [the implementation plan](../plan/local-ocr.plan.md).
Until those gates are recorded, code availability is not a claim of completed device acceptance.
