# OCR and original-image boundaries

- `Domain/OCRModels.swift`: immutable revision/page/span contracts, finite original-space
  geometry, source-bound Locators and bounded recognition settings.
- `Adapters/LocalOCREngine.swift`: serial local Vision recognition, EXIF-normalized image
  decoding, original PDF crop/rotation raster transforms and cancellable job orchestration.
- `Adapters/OCRAdapter.swift`: revision-explicit evidence reads, source-aligned search,
  native/OCR page deduplication and original presentation routing.
- `Adapters/ImageAdapter.swift`: immediate native image presentation without inventing text.
- `Persistence/OCRPersistence.swift`: migration v14, page staging, immutable publication,
  generation/snapshot validation, active-index invalidation and old evidence retention.
- `UI/OCRReaderControls.swift`: local recognition scope, progress, retry, version selection
  and selectable recognized text. No provider calls are made here.
- `UI/OCRPDFOverlay.swift`: bounded-to-visible-page OCR regions owned by PDFKit; only explicit
  selection mode hit-tests. Coordinates are converted by PDFKit, never persisted from screen.
- `UI/OCRImagePresentation.swift`: native image magnification and original-image position
  persistence; decode is cached by managed URL, not repeated on position changes.

See [OCR behavior](../../../../local-ocr.md) and
[implementation/acceptance](../../../../../plan/local-ocr.plan.md).
