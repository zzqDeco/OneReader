# `Sources/OneReader/Agent/ProviderPolicy.swift`

Owns Provider profile validation, endpoint canonicalization, destination
identity, and error/metadata redaction. It rejects URL credentials, query,
fragment, insecure remote transport, non-loopback Ollama, empty model IDs, and
invalid context or timeout bounds before persistence or SDK construction.

The destination identity hashes Provider kind plus canonical effective
endpoint. Remote disclosure uses this value in addition to Space and profile
IDs, so changing a profile host, port, scheme, or base path cannot inherit an
old data-export acknowledgment.
