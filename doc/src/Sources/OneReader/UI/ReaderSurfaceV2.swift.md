# ReaderSurfaceV2.swift

Owns the common reading-surface shell and native header/footer actions. The
source renderer remains `AdapterPresentationView`; chrome must not introduce
another renderer, gesture, zoom controller, or progress persistence path.

- Adaptive Mac header/footer controls measure action width and preserve one
  content tree across reflow. Titles, limitations, saved-position and selection
  labels can wrap. Position text retains its narrow observed-object boundary.
  Navigation receives higher layout priority than flexible position text, so a
  long saved-position label cannot prematurely stack otherwise-fitting actions.
- `ReaderSurfaceFooterLayout` is the actual shell's reusable layout container.
  Source actions remain constructed by the host; the container alone does not
  observe global application state or capture/save progress. Test-only native
  controls exercise that same grouping, not substitute product controls.
- `ReaderSurfaceCompactBar` lays out the iPhone safe-area actions in a grid that
  gains rows before clipping. Each label owns a minimum 44-point hit height;
  actions and their independent accessibility identities remain unchanged.
- PDF adjustment buttons, live percentage and fit-width adapt visually only.
  Requests remain bound to the current presentation token, and native scale/
  selection/position callbacks keep their existing validation and ownership.
- Source ready/loading/unavailable presentation identity, `.id`, capture target,
  Locator, OCR revision and source-selection/position callbacks are not altered
  by the UI refinement. Bilingual availability remains host-controlled/deferred.

Mounted shared chrome regressions cover measured reflow, retained control
identity/current action, compact hit targets and PDF controls. Native visible
acceptance separately verifies the full reader's actual actions; no product
probe factory or accessibility-permission requirement is added. macOS does not
scale system text with Dynamic Type, so these shared layout tests are not
physical-iPhone font, gesture, or visible acceptance evidence.
