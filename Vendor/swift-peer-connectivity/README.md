# Swift Peer Connectivity resolution shim

SwiftAgent 2.0.1 declares `swift-peer-connectivity` for its separate
`SwiftAgentSymbioPeerConnectivity` product. OneReader links only the core
`SwiftAgent` product, but SwiftPM still resolves every package dependency.

The upstream `swift-peer-connectivity` 0.2.5 dependency currently reaches a
`swift-libp2p` manifest requiring Swift tools 6.4, which Xcode 26.6 cannot
load. This source-only package exposes the unused product name without copying
upstream code. `scripts/bootstrap-dependencies.sh` creates an ignored local Git
mirror tagged 0.2.5 and configures SwiftPM before resolution. It avoids the
conflicting-identity path override that SwiftPM warns will become an error.

Remove this shim once the pinned SwiftAgent release no longer resolves that
unrelated package for consumers of the core product.
