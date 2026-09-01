# `Sources/OneReader/Agent/AppleOnDeviceLanguageModel.swift`

Bridges OpenFoundationModels to Apple's native Foundation Models implementation.
It preserves trust boundaries by encoding host instructions, host requests,
registered tools, assistant state, and untrusted Source/tool evidence as
separate sorted JSON fields. Native instructions may follow only the host-owned
request fields; untrusted evidence remains quoted reading data.

Generation options propagate the host response-token ceiling to the native
session. Responses are converted back into the constrained SwiftAgent envelope,
and any tool name outside the supplied registry is rejected.
