import CryptoKit
import Foundation

enum ProviderPolicy {
    static func effectiveEndpoint(for profile: ProviderProfile) throws -> URL? {
        switch profile.kind {
        case .appleOnDevice:
            return nil
        case .openAIResponses:
            return try validate(
                profile.endpoint ?? URL(string: "https://api.openai.com/v1")!,
                allowsLoopbackHTTP: false
            )
        case .anthropicMessages:
            return try validate(
                profile.endpoint ?? URL(string: "https://api.anthropic.com")!,
                allowsLoopbackHTTP: false
            )
        case .ollama:
            return try validate(
                profile.endpoint ?? URL(string: "http://127.0.0.1:11434")!,
                allowsLoopbackHTTP: true,
                requiresLoopback: true
            )
        }
    }

    static func validate(
        _ url: URL,
        allowsLoopbackHTTP: Bool,
        requiresLoopback: Bool = false
    ) throws -> URL {
        guard url.user == nil,
              url.password == nil,
              url.fragment == nil,
              url.query == nil,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            throw ReadingAgentError.invalidProviderEndpoint("malformed")
        }
        let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "localhost"]
        if requiresLoopback, !loopbackHosts.contains(host) {
            throw ReadingAgentError.invalidProviderEndpoint("loopback-required")
        }
        if scheme != "https" {
            guard allowsLoopbackHTTP, scheme == "http", loopbackHosts.contains(host) else {
                throw ReadingAgentError.invalidProviderEndpoint("secure-transport-required")
            }
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ReadingAgentError.invalidProviderEndpoint("malformed")
        }
        components.scheme = scheme
        // Foundation cannot rebuild an IPv6 URL after assigning the unbracketed
        // value returned by URL.host back through URLComponents.host.
        components.percentEncodedHost = host.contains(":") ? "[\(host)]" : host
        if components.path.count > 1 {
            while components.path.hasSuffix("/") {
                components.path.removeLast()
            }
        }
        guard let canonical = components.url else {
            throw ReadingAgentError.invalidProviderEndpoint("malformed")
        }
        guard ProviderEndpointPathPolicy.canonicalPath(for: canonical) != nil else {
            throw ReadingAgentError.invalidProviderEndpoint("ambiguous-path")
        }
        return canonical
    }

    static func normalizedProfile(_ profile: ProviderProfile) throws -> ProviderProfile {
        try validateProfile(profile)
        var normalized = profile
        normalized.displayName = profile.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.modelID = profile.modelID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        normalized.keychainReference = profile.keychainReference?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if profile.endpoint != nil {
            normalized.endpoint = try effectiveEndpoint(for: profile)
        }
        return normalized
    }

    static func destinationIdentity(_ profile: ProviderProfile) throws -> String {
        try validateProfile(profile)
        let endpoint = try effectiveEndpoint(for: profile)?.absoluteString ?? "on-device"
        let payload = "\(profile.kind.rawValue)|\(endpoint)"
        return digest(payload)
    }

    static func revisionIdentity(_ profile: ProviderProfile) throws -> String {
        let profile = try normalizedProfile(profile)
        let endpoint = try effectiveEndpoint(for: profile)?.absoluteString ?? "on-device"
        let capabilities = profile.capabilities.map(\.rawValue).sorted().joined(separator: ",")
        let payload = [
            profile.id,
            profile.kind.rawValue,
            endpoint,
            profile.modelID,
            profile.keychainReference ?? "",
            profile.contextWindow.map(String.init) ?? "",
            String(profile.timeoutSeconds),
            capabilities,
        ].joined(separator: "|")
        return digest(payload)
    }

    static func validateProfile(_ profile: ProviderProfile) throws {
        guard !profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadingAgentError.providerUnavailable("missing-display-name")
        }
        guard !profile.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ReadingAgentError.providerUnavailable("missing-model-id")
        }
        guard profile.timeoutSeconds > 0, profile.timeoutSeconds <= 600 else {
            throw ReadingAgentError.providerUnavailable("invalid-timeout")
        }
        if let contextWindow = profile.contextWindow,
           !(1_024...2_000_000).contains(contextWindow) {
            throw ReadingAgentError.providerUnavailable("invalid-context-window")
        }
        _ = try effectiveEndpoint(for: profile)
        if profile.kind.requiresSecret {
            guard let reference = profile.keychainReference,
                  !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ReadingAgentError.secretMissing
            }
        }
    }

    static func requiresRemoteDisclosure(_ profile: ProviderProfile) throws -> Bool {
        try validateProfile(profile)
        switch profile.kind {
        case .openAIResponses, .anthropicMessages: return true
        case .appleOnDevice, .ollama: return false
        }
    }

    private static func digest(_ payload: String) -> String {
        SHA256.hash(data: Data(payload.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum ProviderEndpointPathPolicy {
    static func canonicalPath(for url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let encoded = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        let lowercased = encoded.lowercased()
        guard !lowercased.contains("%2f"),
              !lowercased.contains("%5c") else {
            return nil
        }
        let segments = encoded.split(separator: "/", omittingEmptySubsequences: false)
        var decodedSegments: [String] = []
        decodedSegments.reserveCapacity(segments.count)
        for segment in segments {
            guard let decoded = String(segment).removingPercentEncoding,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("\\"),
                  !decoded.unicodeScalars.contains(where: {
                      $0.value < 0x20 || $0.value == 0x7f
                  }) else {
                return nil
            }
            decodedSegments.append(decoded)
        }
        let path = decodedSegments.joined(separator: "/")
        return path.isEmpty ? "/" : path
    }
}

enum AgentRedactor {
    static func category(for error: Error) -> String {
        switch error {
        case is CancellationError: "cancelled"
        case let error as ReadingAgentError:
            switch error {
            case .noProvider: "no-provider"
            case .providerUnavailable: "provider-unavailable"
            case .invalidProviderEndpoint: "invalid-endpoint"
            case .secretMissing: "secret-missing"
            case .disclosureRequired: "disclosure-required"
            case .runNotCurrent: "stale-generation"
            case .modelRoundBudgetExceeded: "model-budget"
            case .toolCallBudgetExceeded: "tool-budget"
            case .unknownTool: "unknown-tool"
            case .invalidToolArguments: "invalid-tool-arguments"
            case .invalidStructuredOutput: "invalid-output"
            case .validationRejected: "validation-rejected"
            case .toolExecutionFailed: "tool-failed"
            case .contextBudgetExceeded: "context-budget"
            case .responseBudgetExceeded: "response-budget"
            case .interrupted: "interrupted"
            }
        case is DecodingError: "decode-error"
        default: "runtime-error"
        }
    }

    static func metadata(_ values: [String: String]) -> [String: String] {
        values.reduce(into: [:]) { result, pair in
            let key = pair.key.lowercased()
            let safeTokenMetrics: Set<String> = [
                "inputtokens", "outputtokens", "contexttokens",
            ]
            if key.contains("key")
                || key.contains("secret")
                || (key.contains("token") && !safeTokenMetrics.contains(key))
                || key.contains("path")
                || key.contains("body")
                || key.contains("note") {
                result[pair.key] = "<redacted>"
            } else {
                result[pair.key] = pair.value.count > 256
                    ? String(pair.value.prefix(256)) + "…"
                    : pair.value
            }
        }
    }

    static func publicError(for error: Error) -> Error {
        guard let runtime = error as? ReadingAgentError else {
            return ReadingAgentError.providerUnavailable("runtime-error")
        }
        switch runtime {
        case .noProvider, .secretMissing, .disclosureRequired, .runNotCurrent,
             .modelRoundBudgetExceeded, .toolCallBudgetExceeded,
             .contextBudgetExceeded, .responseBudgetExceeded, .interrupted:
            return runtime
        case .providerUnavailable:
            return ReadingAgentError.providerUnavailable(category(for: runtime))
        case .invalidProviderEndpoint:
            return ReadingAgentError.invalidProviderEndpoint(category(for: runtime))
        case .unknownTool:
            return ReadingAgentError.unknownTool("unregistered")
        case .invalidToolArguments:
            return ReadingAgentError.invalidToolArguments(category(for: runtime))
        case .invalidStructuredOutput:
            return ReadingAgentError.invalidStructuredOutput(category(for: runtime))
        case .validationRejected:
            return ReadingAgentError.validationRejected(category(for: runtime))
        case .toolExecutionFailed:
            return ReadingAgentError.toolExecutionFailed(category(for: runtime))
        }
    }
}
