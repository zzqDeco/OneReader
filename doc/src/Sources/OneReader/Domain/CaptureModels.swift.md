# Capture models

CaptureReceipt is the versioned, bounded handoff contract shared by the host and
the Share Extension. It carries relative payload references and destination
Space IDs, not database paths or credentials.

CaptureJob separates receipt/import phases from SpaceOrganizationState.
CaptureImportContext is an attempt token checked at every publication boundary.
ReadingSpace uses a single persisted organization state and decodes old JSON as
reading without changing progress.
