# `Sources/OneReader/Sources/GitHubBookSource.swift`

Owns public GitHub URL parsing, repository/default-branch discovery, commit
resolution, README table-of-contents parsing, and raw Markdown reads.

It must not contain reading-order or semantic-summary policy. Responses are
bound to the resolved commit SHA, and imported Markdown is treated as untrusted
display data.

