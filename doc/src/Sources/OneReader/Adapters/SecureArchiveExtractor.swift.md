# `Sources/OneReader/Adapters/SecureArchiveExtractor.swift`

Owns the shared ZIP extraction boundary used by EPUB and public GitHub archive
imports. It performs a complete path, collision, symlink, and declared-size
preflight before creating output.

File entries are then expanded through ZIPFoundation's chunk consumer into a
temporary file. One cumulative counter measures bytes actually written across
the archive and aborts immediately at the ratio/absolute ceiling, including
when central-directory sizes are forged. CRC is compared explicitly before the
temporary file is moved to its final snapshot path. Cancellation or validation
failure leaves no committed destination file; the caller owns staging-root
cleanup.
