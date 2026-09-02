# `Sources/OneReader/Agent/AgentOutputValidator.swift`

Owns the side-effect-free model-output trust boundary. It accepts typed
proposals only for the requested task and verifies current Space membership,
the run's exact Snapshot manifest, freshly reprobed adapter selection,
registered capability routes, persisted deterministic probe evidence,
Observation-backed Locators/fragments, relation targets, graph versions, frozen
plan units, and answer quotations.

Adapter confidence, evidence, and capability routes are rebuilt from the fresh
host probe. Alternate primaries, confidence below 0.85, or capability loss can
only become a host-owned confirmation candidate, even if the model supplies a
higher number.

Graph validation rechecks every final unit after applying an incremental patch,
including units inherited from the base graph. A low-confidence AdapterPlan is
returned as a candidate; explicit host confirmation converts it to a
Snapshot-scoped user override only after repeating the same validation. The
validator returns a host-owned `AgentDomainMutation`; it cannot commit directly.
