# Capture coordinator

Host-only actor ahead of ManagedLibrary, RemoteSourceImporter and the existing
AdapterCoordinator. It receives local/remote requests, adopts extension handoffs,
recovers interrupted jobs, and processes one attempt without a Provider.

Recovered imports reuse committed Source/Snapshot/Space IDs. Stale attempt
tokens cannot publish. Removed sources are not resurrected. Redacted errors
describe recovery actions without exposing URL parameters or source content.
AppModel+Capture owns main-actor queue/UI hooks and does not open reading
automatically when background capture completes.
