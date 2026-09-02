import Foundation

enum ProviderKind: String, Codable, CaseIterable, Sendable {
    case appleOnDevice
    case openAIResponses
    case anthropicMessages
    case ollama

    var requiresSecret: Bool {
        switch self {
        case .openAIResponses, .anthropicMessages: true
        case .appleOnDevice, .ollama: false
        }
    }

}

struct ProviderProfile: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var displayName: String
    var kind: ProviderKind
    var endpoint: URL?
    var modelID: String
    var keychainReference: String?
    var isDefault: Bool
    var contextWindow: Int?
    var timeoutSeconds: Double
    var capabilities: Set<ProviderCapability>
    var lastTestedAt: Date?
    var lastTestSucceeded: Bool?
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString.lowercased(),
        displayName: String,
        kind: ProviderKind,
        endpoint: URL? = nil,
        modelID: String,
        keychainReference: String? = nil,
        isDefault: Bool = false,
        contextWindow: Int? = nil,
        timeoutSeconds: Double = 120,
        capabilities: Set<ProviderCapability> = [],
        lastTestedAt: Date? = nil,
        lastTestSucceeded: Bool? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.endpoint = endpoint
        self.modelID = modelID
        self.keychainReference = keychainReference
        self.isDefault = isDefault
        self.contextWindow = contextWindow
        self.timeoutSeconds = timeoutSeconds
        self.capabilities = capabilities
        self.lastTestedAt = lastTestedAt
        self.lastTestSucceeded = lastTestSucceeded
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum ProviderCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case connection
    case streaming
    case structuredGeneration
    case toolCalling
}

struct ProviderConnectionTest: Codable, Hashable, Sendable {
    let profileID: String
    let providerRevisionIdentity: String
    let succeeded: Bool
    let capabilities: Set<ProviderCapability>
    let durationMilliseconds: Int
    let category: String
    let testedAt: Date
}

enum AgentPipelineKind: String, Codable, Hashable, Sendable {
    case readingStructure
}

struct AgentRunRequest: Codable, Hashable, Sendable {
    let spaceID: String
    let task: AgentTaskKind
    let pipeline: AgentPipelineKind?
    let goal: String?
    let question: String?
    let targetSourceID: String?
    let targetSnapshotID: String?
    let expectedSnapshotIDs: Set<String>
    let snapshotManifest: [String: String]

    init(
        spaceID: String,
        task: AgentTaskKind,
        pipeline: AgentPipelineKind? = nil,
        goal: String? = nil,
        question: String? = nil,
        targetSourceID: String? = nil,
        targetSnapshotID: String? = nil,
        expectedSnapshotIDs: Set<String> = [],
        snapshotManifest: [String: String] = [:]
    ) {
        self.spaceID = spaceID
        self.task = task
        self.pipeline = pipeline
        self.goal = goal
        self.question = question
        self.targetSourceID = targetSourceID
        self.targetSnapshotID = targetSnapshotID
        self.expectedSnapshotIDs = expectedSnapshotIDs
        self.snapshotManifest = snapshotManifest
    }
}

struct ReadingPlanDraft: Identifiable, Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let id: String
    let schemaVersion: Int
    let graphID: String
    let graphVersion: String
    let goal: String
    let orderedUnitIDs: [String]
    let reasons: [String: String]
    let createdAt: Date
}

struct EvidenceCitation: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let fragmentID: String?
    let sourceID: String
    let snapshotID: String
    let locator: Locator
    let quote: String
}

struct EvidenceAnswer: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let answer: String
    let citations: [EvidenceCitation]
    let limitations: [String]
}

enum AgentStructuredOutput: Codable, Hashable, Sendable {
    case adapterPlan(AdapterPlan)
    case graphPatch(GraphPatch)
    case readingPlan(ReadingPlanDraft)
    case evidenceAnswer(EvidenceAnswer)
    case scoutingSummary(String)
}

struct AgentModelRequest: Codable, Hashable, Sendable {
    let runID: String
    let generation: Int
    let request: AgentRunRequest
    let correction: String?
}

struct AgentModelResult: Codable, Hashable, Sendable {
    let output: AgentStructuredOutput
    let usage: AgentTokenUsage?
}

struct PersistedAgentOutput: Codable, Hashable, Sendable {
    let runID: String
    let kind: String
    let output: AgentStructuredOutput
    let disposition: String
    let createdAt: Date
}

struct AgentTokenUsage: Codable, Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let durationMilliseconds: Int

    init(
        inputTokens: Int,
        outputTokens: Int,
        durationMilliseconds: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.durationMilliseconds = durationMilliseconds
    }
}

struct AgentRuntimeLimits: Codable, Hashable, Sendable {
    static let standard = AgentRuntimeLimits()

    let maxModelRounds: Int
    let maxToolCalls: Int
    let maxConcurrentTools: Int
    let maxSearchHits: Int
    let maxReadCharacters: Int
    let artifactSpillBytes: Int
    let promptUtilization: Double
    let fallbackContextTokens: Int
    let maxResponseTokens: Int
    let maxResponseBytes: Int
    let maxTransportResponseBytes: Int

    init(
        maxModelRounds: Int = 12,
        maxToolCalls: Int = 64,
        maxConcurrentTools: Int = 4,
        maxSearchHits: Int = 20,
        maxReadCharacters: Int = 16_384,
        artifactSpillBytes: Int = 65_536,
        promptUtilization: Double = 0.70,
        fallbackContextTokens: Int = 32_768,
        maxResponseTokens: Int = 16_384,
        maxResponseBytes: Int = 65_536,
        maxTransportResponseBytes: Int = 1_048_576
    ) {
        self.maxModelRounds = max(1, maxModelRounds)
        self.maxToolCalls = max(1, maxToolCalls)
        self.maxConcurrentTools = min(max(1, maxConcurrentTools), 4)
        self.maxSearchHits = min(max(1, maxSearchHits), 20)
        self.maxReadCharacters = min(max(1, maxReadCharacters), 16_384)
        self.artifactSpillBytes = max(1, artifactSpillBytes)
        self.promptUtilization = min(max(promptUtilization, 0.1), 0.9)
        self.fallbackContextTokens = max(1_024, fallbackContextTokens)
        self.maxResponseTokens = max(1, maxResponseTokens)
        self.maxResponseBytes = max(1, maxResponseBytes)
        self.maxTransportResponseBytes = max(
            self.maxResponseBytes,
            maxTransportResponseBytes
        )
    }

    func promptTokenBudget(contextWindow: Int?) -> Int {
        Int(Double(contextWindow ?? fallbackContextTokens) * promptUtilization)
    }

    func responseTokenBudget(contextWindow: Int?) -> Int {
        let window = max(2, contextWindow ?? fallbackContextTokens)
        let remaining = max(1, window - promptTokenBudget(contextWindow: window))
        return min(maxResponseTokens, remaining)
    }

    func responseByteBudget(contextWindow: Int?) -> Int {
        // Four UTF-8 bytes per requested output token is an explicit byte
        // ceiling in addition to the Provider token limit. The host verifies
        // the actual encoded response even if a Provider ignores its option.
        min(maxResponseBytes, responseTokenBudget(contextWindow: contextWindow) * 4)
    }
}

enum ReadingAgentError: LocalizedError, Equatable, Sendable {
    case noProvider
    case providerUnavailable(String)
    case invalidProviderEndpoint(String)
    case secretMissing
    case disclosureRequired
    case runNotCurrent
    case modelRoundBudgetExceeded(Int)
    case toolCallBudgetExceeded(Int)
    case unknownTool(String)
    case invalidToolArguments(String)
    case invalidStructuredOutput(String)
    case validationRejected(String)
    case toolExecutionFailed(String)
    case contextBudgetExceeded(Int)
    case responseBudgetExceeded(Int)
    case interrupted

    var errorDescription: String? {
        switch self {
        case .noProvider: "未配置可用的模型 Provider。"
        case let .providerUnavailable(category): "Provider 不可用：\(category)"
        case let .invalidProviderEndpoint(category): "Provider endpoint 无效：\(category)"
        case .secretMissing: "Provider 缺少 Keychain 密钥。"
        case .disclosureRequired: "远程 Provider 读取该 Reading Space 前需要确认数据外发说明。"
        case .runNotCurrent: "Agent Run 已被新的来源版本或用户操作取代。"
        case let .modelRoundBudgetExceeded(limit): "模型回合已达到上限：\(limit)。"
        case let .toolCallBudgetExceeded(limit): "工具调用已达到上限：\(limit)。"
        case let .unknownTool(name): "模型请求了未注册工具：\(name)。"
        case let .invalidToolArguments(category): "工具参数无效：\(category)。"
        case let .invalidStructuredOutput(category): "模型结构化输出无效：\(category)。"
        case let .validationRejected(category): "宿主拒绝模型输出：\(category)。"
        case let .toolExecutionFailed(category): "读取工具失败：\(category)。"
        case let .contextBudgetExceeded(limit): "模型上下文超过宿主上限：\(limit) tokens。"
        case let .responseBudgetExceeded(limit): "模型输出超过宿主上限：\(limit) bytes。"
        case .interrupted: "Agent Run 已中断，需要显式恢复。"
        }
    }
}

enum AgentTranscriptRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

enum AgentTranscriptDisposition: String, Codable, Sendable {
    case complete
    case partialFailure
}

struct AgentTranscriptRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runID: String
    let sequence: Int
    let role: AgentTranscriptRole
    let disposition: AgentTranscriptDisposition
    let content: Data
    let createdAt: Date
}

struct AgentContextSnapshot: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let runID: String
    let sequence: Int
    let fullTranscriptJSON: Data
    let projectedTranscriptJSON: Data
    let projectionAuditJSON: Data
    let createdAt: Date
}

struct AgentModelCallMetric: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case generation
        case summary
    }

    enum Outcome: String, Codable, Sendable {
        case succeeded
        case failed
        case cancelled
    }

    let id: String
    let runID: String
    let round: Int
    let kind: Kind
    let outcome: Outcome
    let inputBytes: Int
    let outputBytes: Int
    let inputTokenUpperBound: Int
    let outputTokenUpperBound: Int
    let durationMilliseconds: Int
    let createdAt: Date
}
