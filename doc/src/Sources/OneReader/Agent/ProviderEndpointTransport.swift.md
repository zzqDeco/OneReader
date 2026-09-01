# `Sources/OneReader/Agent/ProviderEndpointTransport.swift`

Owns the transport guard needed because the pinned Provider SDKs construct
private sessions from `URLSessionConfiguration.default` and expose no session
injection point. Under a process construction lock, OneReader temporarily
exchanges the default getter only for synchronous SDK model creation, installs
a Provider-only protocol plus opaque scope token in that returned configuration, and restores the
getter before model construction returns. Default Source/browser sessions are
not registered or intercepted.

The model instance retains a lease mapping an opaque request token to the
profile's exact validated scheme, host, port, and base path. Requests outside
that scope or after the lease is released fail closed. Allowed requests run through a
non-caching ephemeral inner session with custom protocols disabled, and every
HTTP redirect is refused for both ordinary data and streaming paths. Completion
errors are reduced to redacted runtime categories before returning to the SDK.
Each lease also owns a 1 MiB per-response raw response-body ceiling. The URL
protocol counts all data callbacks, rejects an oversized declared length before
delivery, cancels cumulative HTTP/SSE/NDJSON overflow, and records the observed
violation for the model boundary to audit as `response-budget`. A lease may add
a separate cumulative ceiling across requests; Provider capability probes use
it so repeated individually bounded responses cannot evade the total budget.
The guard does not fetch Sources and does not grant the Agent a general network
tool.
