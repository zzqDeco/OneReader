# Architecture

## Product boundary

OneReader exposes heterogeneous material as an explorable, locatable content
space. The reader operates on virtual reading units without forcing PDFs and
repositories into one physical document format.

## Runtime layers

```text
Source driver
    ↓
Immutable source snapshot
    ↓
Observation and source fragment
    ↓
Semantic mapper
    ↓
Versioned reading graph
    ↓
Goal-specific reading plan
    ↓
SwiftUI reader + local progress
```

The MVP uses a deterministic semantic mapper. It implements the same boundary a
future AI mapper will use, which keeps network-model behavior out of source
drivers and preserves repeatable tests.

## Native composition

- SwiftUI owns window structure, navigation, inspector, selection, loading
  state, and accessibility.
- PDFKit owns PDF layout, zooming, page display, and page navigation.
- Foundation `URLSession` owns public GitHub metadata and raw file reads.
- The application state coordinates source snapshots, graph refinement,
  reading-plan projection, stale-result suppression, and progress.
- A versioned JSON store under Application Support owns progress.

## Data flow

### GitHub book

1. Parse a public GitHub repository URL.
2. Read repository metadata and resolve its default branch.
3. resolve the branch to an exact commit SHA.
4. read `README.md` and discover Markdown table-of-contents links.
5. create one repository snapshot and one source fragment per reading unit.
6. fetch Markdown lazily when the user selects a unit.

If GitHub metadata fails, the bundled public demonstration can expose its known
chapter locators, but it remains visibly marked as an unresolved revision until
live resolution succeeds.

### PDF

1. Read remote data or a user-selected local PDF.
2. calculate a SHA-256 content digest.
3. create a PDF snapshot and inspect PDFKit outline destinations.
4. create outline-based units, or bounded page groups when no outline exists.
5. render the selected page through a native `PDFView`.

### Planning and progress

The mapper creates graph nodes and typed relations. The planner then projects
that graph for one goal:

- quick overview: high-value, low-effort units first while preserving the
  introduction;
- systematic: source order;
- review: incomplete units first.

Plans are stable projections. Changing a goal creates a new projection; reading
the same graph does not continually reorder the active route.

## Trust boundaries

- Repository Markdown and PDF text are untrusted content.
- Source content never becomes executable instructions.
- No token or API key is required or stored by the MVP.
- GitHub calls use public endpoints and disclose only the requested public
  repository coordinates.
- Local PDF bytes do not leave the machine.
- Evidence navigation is rejected or marked stale when its revision no longer
  matches the active snapshot.

## Deferred work

- pluggable hosted or local AI mapper
- OCR and scanned-document anchors
- semantic search and cross-source claim verification
- local Git working-copy driver with security-scoped bookmarks
- notes, annotations, sync, and account identity
- signed and notarized distribution

