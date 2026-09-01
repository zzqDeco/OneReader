# `Sources/OneReader/Agent/ProviderConnectionTester.swift`

Runs the explicit Provider connection test for structured generation, one
exact-nonce tool call, and streaming. Every phase has a cancellation-resistant
deadline, explicit response-token options, the shared 1 MiB raw transport cap,
and a 4 KiB logical streaming snapshot bound. One host budget permits at most
two structured responses, exactly one nonce tool invocation, and one stream;
the entire probe shares one timeout and one cumulative raw transport allowance.
Repeated or concurrent tool calls fail closed. Anthropic cumulative prefixes
are compared as exact UTF-8 bytes and normalized before session aggregation;
combining marks and ZWJ suffixes are supported, while normalization-equivalent
byte rewrites fail closed. The final stream value must be the exact literal `ok`
rather than merely non-empty content.

The test captures the normalized Provider revision before any model call. Its
result carries that identity, and persistence uses a single-transaction compare
and swap against the current profile. If endpoint, model, secret reference, or
another run-relevant field changes during the test, the old result returns as
`stale-provider-revision` and cannot write capabilities/status or invalidate a
Run created for the replacement configuration.
