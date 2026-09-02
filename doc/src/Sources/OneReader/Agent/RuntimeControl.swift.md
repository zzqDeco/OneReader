# `Sources/OneReader/Agent/RuntimeControl.swift`

Owns generation clocks, model/tool budgets, the cancellation-safe four-permit
read gate, ordered Activity/transcript recording, and four-stage context
projection. Context size uses a conservative UTF-8 byte upper bound plus
structure overhead; it never uses bytes divided by an assumed tokenizer ratio.

Projection preserves the current tail and applies digest deduplication,
Artifact handles, completed-phase folding, and only then a model summary. The
summary output is bounded, and the base-model summarizer chunks history and
checks each encoded model transcript against the same hard input limit. The
full durable transcript is never replaced by the projected view.
Transcript sequence allocation lives in the serialized database write path, so
model-failure audits and ordinary recorder entries cannot race on a stale local
counter. Before closing an Activity stream, the recorder replays persisted
events at or beyond its next sequence. Persisted cancellation/supersession is
therefore visible even when the worker reaches recorder shutdown before the
session actor publishes that terminal event.
