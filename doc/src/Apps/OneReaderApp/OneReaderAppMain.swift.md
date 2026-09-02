# `Apps/OneReaderApp/OneReaderAppMain.swift`

Owns only the executable `@main` boundary. SwiftPM, the native macOS target, and
the universal iPhone/iPad target all launch the public shared `OneReaderScene`.
No domain state, platform permissions, adapter routing, or persistence belongs
in this wrapper.
