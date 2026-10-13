# Capture models

CaptureReceipt is the versioned, bounded handoff contract shared by the host and
the Share Extension. It carries relative payload references and destination
Space IDs, not database paths or credentials.

Schema v2 binds local receipt identity to a payload-tree SHA-256 digest.
describesSameContent never equates digest-less legacy local receipts; exact
remote URL receipts remain compatible across schema v1/v2.

CaptureJob separates receipt/import phases from SpaceOrganizationState.
CaptureImportContext is an attempt token checked at every publication boundary.
ReadingSpace uses a single persisted organization state and decodes old JSON as
reading without changing progress.
