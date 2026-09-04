# Third-party notices

OneReader is licensed under Apache-2.0. It incorporates or links against the
packages below. Their licenses apply to their own code and do not replace the
OneReader license.

The release packager copies the available upstream license and NOTICE files
into `OneReader.app/Contents/Resources/Licenses/`. Versions and revisions are
locked by `Package.resolved`.

| Package | Locked version | Upstream license |
| --- | --- | --- |
| SwiftAgent | 2.0.1 | MIT, declared in the pinned README; no standalone license file in the tag |
| AnyFoundationModels | 0.5.5 | MIT, declared in the pinned README; no standalone license file in the tag |
| OpenFoundationModels | 1.18.0 | MIT |
| GRDB.swift | 7.10.0 | MIT |
| ZIPFoundation | 0.9.20 | MIT |
| SwiftSoup | 2.13.9 | MIT |
| swift-markdown | 0.8.0 | Apache-2.0 with Runtime Library Exception |
| eventsource | 1.5.1 | MIT |
| JSONSchema | 1.3.1 | MIT |
| swift-actor-runtime | 0.6.1 | MIT |
| swift-configuration | 1.2.0 | Apache-2.0 with Runtime Library Exception |
| swift-distributed-tracing | 1.4.1 | Apache-2.0 with Runtime Library Exception |
| swift-metrics | 2.11.0 | Apache-2.0 with Runtime Library Exception |
| swift-syntax | 602.0.0 | Apache-2.0 with Runtime Library Exception |
| swift-cmark | 0.8.0 | MIT |
| swift-collections | 1.6.0 | Apache-2.0 with Runtime Library Exception |
| swift-atomics | 1.3.1 | Apache-2.0 with Runtime Library Exception |
| swift-log | 1.15.0 | Apache-2.0 with Runtime Library Exception |
| swift-nio | 2.101.3 | Apache-2.0 with Runtime Library Exception |
| swift-service-context | 1.3.0 | Apache-2.0 with Runtime Library Exception |
| swift-service-lifecycle | 2.12.0 | Apache-2.0 with Runtime Library Exception |
| swift-system | 1.8.1 | Apache-2.0 with Runtime Library Exception |
| swift-yaml | 1.0.1 | MIT |
| swift-sdk | 0.12.1 | Apache-2.0 |

Swift Package Manager can resolve packages for products and traits that
OneReader does not link. In particular, `swift-peer-connectivity`,
`swift-skills`, and `swift-generation` can appear in `Package.resolved` through
unused SwiftAgent products. OneReader does not import or link those products.

The SwiftAgent and AnyFoundationModels pinned tags declare MIT in their README
but omit a standalone license text. This upstream metadata gap is recorded
rather than silently treating an inferred file as authoritative. Re-audit it
before a notarized stable binary release.
