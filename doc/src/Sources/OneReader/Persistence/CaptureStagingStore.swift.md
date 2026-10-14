# Capture staging store

This Foundation-only file is compiled directly into the host and extension.
It owns bounded attachment copies, capacity/path/symlink checks, atomic
write-sync-rename receipts, adoption, acknowledgments, and the small destination
catalog. The extension never links the main Library or Provider runtime.

Before reusing a local task ID it stages and hashes the candidate payload,
including directory structure, then validates the existing payload against its
stored digest. Every replay/adoption/acknowledgment fails closed on mismatches or
legacy local receipts without a digest. Conflicting candidates never overwrite
the original ready payload.

Only ready directories are eligible for handoff. Incomplete writers are not
automatically deleted across process boundaries. Completed payload cleanup
requires a durable host import receipt; cancelled and failed payloads remain.
