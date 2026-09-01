import Foundation
import ObjectiveC.runtime

private struct ProviderEndpointScope: Hashable, Sendable {
    let scheme: String
    let host: String
    let port: Int
    let basePath: String

    init(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw ReadingAgentError.invalidProviderEndpoint("transport-scope")
        }
        self.scheme = scheme
        self.host = host
        port = url.port ?? (scheme == "https" ? 443 : 80)
        guard let path = ProviderEndpointPathPolicy.canonicalPath(for: url) else {
            throw ReadingAgentError.invalidProviderEndpoint("transport-path")
        }
        basePath = path.count > 1 && path.hasSuffix("/")
            ? String(path.dropLast())
            : path
    }

    func contains(_ url: URL) -> Bool {
        guard url.user == nil,
              url.password == nil,
              url.scheme?.lowercased() == scheme,
              url.host?.lowercased() == host,
              (url.port ?? (scheme == "https" ? 443 : 80)) == port,
              let candidate = ProviderEndpointPathPolicy.canonicalPath(for: url) else {
            return false
        }
        return basePath == "/"
            || candidate == basePath
            || candidate.hasPrefix(basePath + "/")
    }
}

private final class ProviderEndpointLeaseState: @unchecked Sendable {
    let scope: ProviderEndpointScope
    let maximumResponseBytes: Int
    let maximumCumulativeResponseBytes: Int?

    private let lock = NSLock()
    private var cumulativeResponseBytes = 0
    private var responseLimitViolation: (limit: Int, observedBytes: Int)?

    init(
        scope: ProviderEndpointScope,
        maximumResponseBytes: Int,
        maximumCumulativeResponseBytes: Int?
    ) {
        self.scope = scope
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.maximumCumulativeResponseBytes = maximumCumulativeResponseBytes.map {
            max(1, $0)
        }
    }

    func preflight(expectedResponseBytes: Int) -> (limit: Int, observedBytes: Int)? {
        lock.lock()
        defer { lock.unlock() }
        if let responseLimitViolation { return responseLimitViolation }
        let expectedResponseBytes = max(0, expectedResponseBytes)
        if expectedResponseBytes > maximumResponseBytes {
            return recordViolationLocked(
                limit: maximumResponseBytes,
                observedBytes: expectedResponseBytes
            )
        }
        if let maximumCumulativeResponseBytes {
            let addition = cumulativeResponseBytes.addingReportingOverflow(
                expectedResponseBytes
            )
            let projected = addition.overflow ? Int.max : addition.partialValue
            if projected > maximumCumulativeResponseBytes {
                return recordViolationLocked(
                    limit: maximumCumulativeResponseBytes,
                    observedBytes: projected
                )
            }
        }
        return nil
    }

    func consume(
        responseBytes: Int,
        additionalBytes: Int
    ) -> (limit: Int, observedBytes: Int)? {
        lock.lock()
        defer { lock.unlock() }
        if let responseLimitViolation { return responseLimitViolation }
        let addition = cumulativeResponseBytes.addingReportingOverflow(
            max(0, additionalBytes)
        )
        cumulativeResponseBytes = addition.overflow ? .max : addition.partialValue
        if responseBytes > maximumResponseBytes {
            return recordViolationLocked(
                limit: maximumResponseBytes,
                observedBytes: responseBytes
            )
        }
        if let maximumCumulativeResponseBytes,
           cumulativeResponseBytes > maximumCumulativeResponseBytes {
            return recordViolationLocked(
                limit: maximumCumulativeResponseBytes,
                observedBytes: cumulativeResponseBytes
            )
        }
        return nil
    }

    func recordedResponseLimitViolation() -> (limit: Int, observedBytes: Int)? {
        lock.lock()
        defer { lock.unlock() }
        return responseLimitViolation
    }

    private func recordViolationLocked(
        limit: Int,
        observedBytes: Int
    ) -> (limit: Int, observedBytes: Int) {
        let minimumObserved = limit == .max ? .max : limit + 1
        let violation = (
            limit: limit,
            observedBytes: max(minimumObserved, observedBytes)
        )
        responseLimitViolation = violation
        return violation
    }
}

private final class ProviderEndpointScopeRegistry: @unchecked Sendable {
    static let shared = ProviderEndpointScopeRegistry()

    private let lock = NSLock()
    private var activeStatesByToken: [String: ProviderEndpointLeaseState] = [:]

    func register(
        _ endpoint: URL,
        maximumResponseBytes: Int,
        maximumCumulativeResponseBytes: Int?
    ) throws -> String {
        let state = try ProviderEndpointLeaseState(
            scope: ProviderEndpointScope(url: endpoint),
            maximumResponseBytes: maximumResponseBytes,
            maximumCumulativeResponseBytes: maximumCumulativeResponseBytes
        )
        let token = UUID().uuidString.lowercased()
        lock.lock()
        activeStatesByToken[token] = state
        lock.unlock()
        return token
    }

    func unregister(_ token: String) {
        lock.lock()
        activeStatesByToken.removeValue(forKey: token)
        lock.unlock()
    }

    func state(for token: String) -> ProviderEndpointLeaseState? {
        lock.lock()
        let result = activeStatesByToken[token]
        lock.unlock()
        return result
    }
}

final class ProviderEndpointTransportLease: @unchecked Sendable {
    private let token: String
    private let lock = NSLock()
    private var isActive = true

    fileprivate init(token: String) {
        self.token = token
    }

    deinit {
        invalidate()
    }

    func invalidate() {
        lock.lock()
        let shouldUnregister = isActive
        isActive = false
        lock.unlock()
        if shouldUnregister {
            ProviderEndpointScopeRegistry.shared.unregister(token)
        }
    }

    func construct<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        let active = isActive
        lock.unlock()
        guard active else {
            throw ReadingAgentError.providerUnavailable("transport-expired")
        }
        return try ProviderEndpointTransport.withGuardedDefault(
            token: token,
            body
        )
    }

    func responseLimitViolation() -> (limit: Int, observedBytes: Int)? {
        ProviderEndpointScopeRegistry.shared.state(for: token)?
            .recordedResponseLimitViolation()
    }
}

enum ProviderEndpointTransport {
    private static let constructionLock = NSLock()
    fileprivate static let threadScopeTokenKey =
        "OneReader.ProviderEndpointTransport.scopeToken"

    static func makeLease(
        endpoint: URL,
        maximumResponseBytes: Int = AgentRuntimeLimits.standard.maxTransportResponseBytes,
        maximumCumulativeResponseBytes: Int? = nil
    ) throws -> ProviderEndpointTransportLease {
        ProviderEndpointTransportLease(
            token: try ProviderEndpointScopeRegistry.shared.register(
                endpoint,
                maximumResponseBytes: maximumResponseBytes,
                maximumCumulativeResponseBytes: maximumCumulativeResponseBytes
            )
        )
    }

    fileprivate static func withGuardedDefault<T>(
        token: String,
        _ body: () throws -> T
    ) throws -> T {
        constructionLock.lock()
        defer { constructionLock.unlock() }
        guard let original = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(getter: URLSessionConfiguration.default)
        ), let replacement = class_getClassMethod(
            URLSessionConfiguration.self,
            #selector(URLSessionConfiguration.oneReaderScopedDefault)
        ) else {
            throw ReadingAgentError.providerUnavailable("transport-installation")
        }

        Thread.current.threadDictionary[threadScopeTokenKey] = token
        method_exchangeImplementations(original, replacement)
        defer {
            method_exchangeImplementations(original, replacement)
            Thread.current.threadDictionary.removeObject(forKey: threadScopeTokenKey)
        }
        return try body()
    }
}

private extension URLSessionConfiguration {
    @objc class func oneReaderScopedDefault() -> URLSessionConfiguration {
        // While the two class methods are exchanged this selector invokes
        // Foundation's original default configuration implementation.
        let configuration = oneReaderScopedDefault()
        guard let token = Thread.current.threadDictionary[
            ProviderEndpointTransport.threadScopeTokenKey
        ] as? String else {
            return configuration
        }
        var protocolClasses = configuration.protocolClasses ?? []
        if !protocolClasses.contains(where: { $0 == ProviderEndpointURLProtocol.self }) {
            protocolClasses.insert(ProviderEndpointURLProtocol.self, at: 0)
            configuration.protocolClasses = protocolClasses
        }
        var headers = configuration.httpAdditionalHeaders ?? [:]
        headers[ProviderEndpointURLProtocol.scopeTokenHeader] = token
        configuration.httpAdditionalHeaders = headers
        return configuration
    }
}

class ProviderEndpointURLProtocol: URLProtocol, URLSessionDataDelegate,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private static let handledKey = "OneReader.ProviderEndpointURLProtocol.handled"
    static let scopeTokenHeader = "X-OneReader-Provider-Scope-Token"

    private let stateLock = NSLock()
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var stopped = false
    private var responseByteCount = 0
    private var leaseState: ProviderEndpointLeaseState?

    override class func canInit(with request: URLRequest) -> Bool {
        guard URLProtocol.property(forKey: handledKey, in: request) == nil,
              let scheme = request.url?.scheme?.lowercased() else { return false }
        // A Provider-only configuration routes every HTTP(S) request through
        // this protocol. `startLoading` rejects inactive or out-of-scope URLs.
        return scheme == "https" || scheme == "http"
    }

    override class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest ?? task.originalRequest else { return false }
        return canInit(with: request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let token = request.value(forHTTPHeaderField: Self.scopeTokenHeader),
              let leaseState = ProviderEndpointScopeRegistry.shared.state(for: token),
              leaseState.scope.contains(url),
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else {
            client?.urlProtocol(
                self,
                didFailWithError: ReadingAgentError.invalidProviderEndpoint(
                    "request-outside-scope"
                )
            )
            return
        }
        if let violation = leaseState.recordedResponseLimitViolation() {
            client?.urlProtocol(
                self,
                didFailWithError: ReadingAgentError.responseBudgetExceeded(
                    violation.limit
                )
            )
            return
        }
        mutable.setValue(nil, forHTTPHeaderField: Self.scopeTokenHeader)
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: nil
        )
        let task = session.dataTask(with: mutable as URLRequest)
        stateLock.lock()
        self.session = session
        dataTask = task
        self.leaseState = leaseState
        responseByteCount = 0
        stateLock.unlock()
        task.resume()
    }

    override func stopLoading() {
        stateLock.lock()
        stopped = true
        let task = dataTask
        let session = session
        dataTask = nil
        self.session = nil
        stateLock.unlock()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Provider endpoints are canonical. Refuse every redirect rather than
        // forwarding credentials or request bodies across destinations.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        stateLock.lock()
        let leaseState = self.leaseState
        stateLock.unlock()
        if response.expectedContentLength >= 0,
           let leaseState,
           let violation = leaseState.preflight(
               expectedResponseBytes: Int(response.expectedContentLength)
           ) {
            completionHandler(.cancel)
            failForResponseBudget(
                violation: violation
            )
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        stateLock.lock()
        guard !stopped, let leaseState else {
            stateLock.unlock()
            return
        }
        let addition = responseByteCount.addingReportingOverflow(data.count)
        let nextByteCount = addition.overflow ? Int.max : addition.partialValue
        if let violation = leaseState.consume(
            responseBytes: nextByteCount,
            additionalBytes: data.count
        ) {
            stateLock.unlock()
            failForResponseBudget(violation: violation)
            return
        }
        responseByteCount = nextByteCount
        stateLock.unlock()
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        stateLock.lock()
        let shouldNotify = !stopped
        dataTask = nil
        self.session = nil
        stateLock.unlock()
        guard shouldNotify else { return }
        if let error {
            client?.urlProtocol(
                self,
                didFailWithError: ReadingAgentError.providerUnavailable(
                    AgentRedactor.category(for: error)
                )
            )
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        session.finishTasksAndInvalidate()
    }

    private func failForResponseBudget(
        violation: (limit: Int, observedBytes: Int)
    ) {
        stateLock.lock()
        guard !stopped else {
            stateLock.unlock()
            return
        }
        stopped = true
        let task = dataTask
        let session = self.session
        dataTask = nil
        self.session = nil
        stateLock.unlock()

        task?.cancel()
        session?.invalidateAndCancel()
        client?.urlProtocol(
            self,
            didFailWithError: ReadingAgentError.responseBudgetExceeded(
                violation.limit
            )
        )
    }
}
