import CryptoKit
import Foundation
import RepoPromptRemoteProtocol

enum RemoteGatewayError: LocalizedError {
    case invalidResponse
    case attachmentRejected(String)
    case httpStatus(Int, RemoteErrorResponse?)
    case protocolMismatch(Int)
    case certificateMismatch
    case snapshotRequired
    case credentialRejected

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The Mac returned an invalid response."
        case let .attachmentRejected(message): message
        case let .httpStatus(status, error): error?.message ?? "The Mac returned HTTP \(status)."
        case let .protocolMismatch(version): "This Mac requires an unsupported remote protocol version (\(version))."
        case .certificateMismatch: "The Mac identity did not match the pairing record."
        case .snapshotRequired: "The saved event cursor is no longer available; a fresh snapshot is required."
        case .credentialRejected: "The paired Mac rejected this credential; re-pairing is required."
        }
    }
}

enum RemoteTransportKind: Equatable {
    case legacyHTTPS
    case iroh
}

protocol RemoteGatewayTransport: AnyObject {
    var kind: RemoteTransportKind { get }
    var irohPath: RemoteIrohPathKind? { get }

    func unpair() async throws
    func snapshot() async throws -> RemoteSnapshot
    func diagnostics() async throws -> RemoteDiagnostics
    func workspaces() async throws -> [RemoteWorkspaceSummary]
    func sessions() async throws -> [RemoteSessionSummary]
    func agents() async throws -> [RemoteAgentDescriptor]
    func workflows() async throws -> [RemoteWorkflowDescriptor]
    func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse
    func command(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse
    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage
    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int?,
        itemID: UUID?,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPage
    func recentTranscript(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor?,
        limit: Int
    ) async throws -> RemoteTranscriptPage
    func events(after cursor: UInt64) -> AsyncThrowingStream<RemoteEvent, Error>
    func close()
}

extension RemoteGatewayTransport {
    var irohPath: RemoteIrohPathKind? { nil }
    func close() {}

    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int,
        limit: Int = 100,
        includeDetails: Bool = false
    ) async throws -> RemoteTranscriptPage {
        try await transcript(
            sessionID: sessionID,
            afterSequenceIndex: afterSequenceIndex,
            itemID: nil,
            limit: limit,
            includeDetails: includeDetails
        )
    }

    func transcript(
        sessionID: UUID,
        itemID: UUID,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPage {
        try await transcript(
            sessionID: sessionID,
            afterSequenceIndex: nil,
            itemID: itemID,
            limit: limit,
            includeDetails: includeDetails
        )
    }

    func recentTranscript(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor? = nil
    ) async throws -> RemoteTranscriptPage {
        try await recentTranscript(sessionID: sessionID, before: cursor, limit: 100)
    }
}

private final class RemotePinnedSessionDelegate: NSObject, URLSessionDelegate {
    let expectedCertificateSHA256: String?

    init(expectedCertificateSHA256: String?) {
        self.expectedCertificateSHA256 = expectedCertificateSHA256?.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let expectedCertificateSHA256
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        guard let certificate = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
              let certificateData = SecCertificateCopyData(certificate) as Data?
        else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let digest = SHA256.hash(data: certificateData)
            .map { String(format: "%02x", $0) }
            .joined()
        guard digest == expectedCertificateSHA256 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

final class RemoteHTTPSGatewayTransport: RemoteGatewayTransport {
    let kind = RemoteTransportKind.legacyHTTPS
    let baseURL: URL
    private let credential: String?
    private let session: URLSession

    init(baseURL: URL, credential: String? = nil, certificateSHA256: String? = nil) {
        self.baseURL = baseURL
        self.credential = credential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        session = URLSession(
            configuration: configuration,
            delegate: RemotePinnedSessionDelegate(expectedCertificateSHA256: certificateSHA256),
            delegateQueue: nil
        )
    }

    func pair(_ request: RemotePairingRequest) async throws -> RemotePairingResponse {
        try await send(path: RemoteProtocol.pairingPath, method: "POST", body: request, includeCredential: false)
    }

    func unpair() async throws {
        let response: RemoteUnpairResponse = try await send(path: RemoteProtocol.unpairPath, method: "POST")
        guard RemoteProtocol.supports(response.protocolVersion), response.unpaired else {
            throw RemoteGatewayError.invalidResponse
        }
    }

    func snapshot() async throws -> RemoteSnapshot {
        let snapshot: RemoteSnapshot = try await send(path: RemoteProtocol.snapshotPath, method: "GET")
        guard RemoteProtocol.supports(snapshot.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(snapshot.protocolVersion)
        }
        return snapshot
    }

    func diagnostics() async throws -> RemoteDiagnostics {
        let response: RemoteDiagnostics = try await send(path: RemoteProtocol.diagnosticsPath, method: "GET")
        guard RemoteProtocol.supports(response.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(response.protocolVersion)
        }
        return response
    }

    func workspaces() async throws -> [RemoteWorkspaceSummary] {
        try await send(path: RemoteProtocol.workspacesPath, method: "GET")
    }

    func sessions() async throws -> [RemoteSessionSummary] {
        try await send(path: RemoteProtocol.sessionsPath, method: "GET")
    }

    func agents() async throws -> [RemoteAgentDescriptor] {
        try await send(path: RemoteProtocol.agentsPath, method: "GET")
    }

    func workflows() async throws -> [RemoteWorkflowDescriptor] {
        try await send(path: RemoteProtocol.workflowsPath, method: "GET")
    }

    func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let response: RemoteCommandResponse = try await send(
            path: RemoteProtocol.contextBuilderPath,
            method: "POST",
            body: request
        )
        guard RemoteProtocol.supports(response.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(response.protocolVersion)
        }
        return response
    }

    func command(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        let response: RemoteCommandResponse = try await send(
            path: RemoteProtocol.commandsPath,
            method: "POST",
            body: request
        )
        guard RemoteProtocol.supports(response.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(response.protocolVersion)
        }
        return response
    }

    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage {
        let response: RemoteHistoryPage = try await send(
            path: RemoteProtocol.historyPath,
            method: "GET",
            queryItems: Self.historyQueryItems(request)
        )
        guard RemoteProtocol.supports(response.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(response.protocolVersion)
        }
        return response
    }

    static func historyQueryItems(_ request: RemoteHistoryRPCRequest) -> [URLQueryItem] {
        var items = [
            request.query.map { URLQueryItem(name: "q", value: $0) },
            request.workspaceID.map { URLQueryItem(name: "workspace_id", value: $0.uuidString) },
            URLQueryItem(name: "limit", value: String(request.limit))
        ].compactMap { $0 }
        if let before = request.before {
            items.append(URLQueryItem(name: "before_date", value: String(before.lastActivityAt.timeIntervalSinceReferenceDate)))
            items.append(URLQueryItem(name: "before_id", value: before.sessionID.uuidString))
        }
        return items
    }

    func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int? = nil,
        itemID: UUID? = nil,
        limit: Int = 100,
        includeDetails: Bool = false
    ) async throws -> RemoteTranscriptPage {
        let response: RemoteTranscriptPage = try await send(
            path: RemoteProtocol.transcriptPath,
            method: "GET",
            queryItems: Self.transcriptQueryItems(
                sessionID: sessionID,
                afterSequenceIndex: afterSequenceIndex,
                itemID: itemID,
                limit: limit,
                includeDetails: includeDetails
            )
        )
        guard RemoteProtocol.supports(response.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(response.protocolVersion)
        }
        return response
    }

    /// Opt-in newest-window/backward paging. A legacy server ignores the new
    /// query keys and returns a page without `pagingMode`; callers detect that
    /// response and continue with the legacy `after` cursor.
    func recentTranscript(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor? = nil,
        limit: Int = 100
    ) async throws -> RemoteTranscriptPage {
        let response: RemoteTranscriptPage = try await send(
            path: RemoteProtocol.transcriptPath,
            method: "GET",
            queryItems: try Self.transcriptQueryItems(
                sessionID: sessionID,
                before: cursor,
                limit: limit
            )
        )
        guard RemoteProtocol.supports(response.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(response.protocolVersion)
        }
        return response
    }

    static func transcriptQueryItems(
        sessionID: UUID,
        afterSequenceIndex: Int? = nil,
        itemID: UUID? = nil,
        limit: Int = 100,
        includeDetails: Bool = false
    ) -> [URLQueryItem] {
        [
            URLQueryItem(name: "session_id", value: sessionID.uuidString),
            afterSequenceIndex.map { URLQueryItem(name: "after", value: String($0)) },
            itemID.map { URLQueryItem(name: "item_id", value: $0.uuidString) },
            URLQueryItem(name: "limit", value: String(limit)),
            includeDetails ? URLQueryItem(name: "details", value: "1") : nil
        ].compactMap { $0 }
    }

    static func transcriptQueryItems(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor?,
        limit: Int = 100
    ) throws -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "session_id", value: sessionID.uuidString),
            URLQueryItem(name: "order", value: "recent"),
            URLQueryItem(name: "limit", value: String(limit))
        ]
        if let cursor {
            let data = try JSONEncoder().encode(cursor)
            let encoded = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            items.append(URLQueryItem(name: "before", value: encoded))
        }
        return items
    }

    func events(after cursor: UInt64) -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let bytes = try await eventBytes(after: cursor)
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let event = Self.decodeEventLine(line) {
                            continuation.yield(event)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func decodeEventLine(_ line: String) -> RemoteEvent? {
        let payload = line.hasPrefix("data:")
            ? String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            : line
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(RemoteEvent.self, from: data)
    }

    private func eventBytes(after cursor: UInt64) async throws -> URLSession.AsyncBytes {
        var components = URLComponents(url: baseURL.appendingPathComponent(String(RemoteProtocol.eventsPath.dropFirst())), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "after", value: String(cursor))]
        guard let url = components?.url else { throw RemoteGatewayError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthorization(to: &request)

        let (bytes, response) = try await session.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 300).contains(httpResponse.statusCode)
        {
            var body = Data()
            for try await byte in bytes {
                body.append(byte)
            }
            try validate(response, data: body)
        }
        try validate(response)
        return bytes
    }

    func transportBootstrap() async throws -> RemoteTransportBootstrapResponse {
        try await send(path: RemoteProtocol.transportBootstrapPath, method: "GET")
    }

    func bindIrohEndpoint(_ request: RemoteIrohBindingRequest) async throws -> RemoteIrohBindingResponse {
        try await send(path: RemoteProtocol.irohBindingPath, method: "POST", body: request)
    }

    func close() {
        session.invalidateAndCancel()
    }

    private func send<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body? = nil,
        queryItems: [URLQueryItem] = [],
        includeCredential: Bool = true
    ) async throws -> Response {
        var components = URLComponents(
            url: baseURL.appendingPathComponent(String(path.dropFirst())),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else { throw RemoteGatewayError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if includeCredential { applyAuthorization(to: &request) }

        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw RemoteGatewayError.invalidResponse
        }
    }

    private func send<Response: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        includeCredential: Bool = true
    ) async throws -> Response {
        try await send(
            path: path,
            method: method,
            body: Optional<String>.none,
            queryItems: queryItems,
            includeCredential: includeCredential
        )
    }

    private func applyAuthorization(to request: inout URLRequest) {
        guard let credential else { return }
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
    }

    private func validate(_ response: URLResponse, data: Data? = nil) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw RemoteGatewayError.invalidResponse }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let decodedError = data.flatMap { try? JSONDecoder().decode(RemoteErrorResponse.self, from: $0) }
            if httpResponse.statusCode == 409, decodedError?.code == "snapshot_required" {
                throw RemoteGatewayError.snapshotRequired
            }
            if httpResponse.statusCode == 401 {
                throw RemoteGatewayError.credentialRejected
            }
            throw RemoteGatewayError.httpStatus(httpResponse.statusCode, decodedError)
        }
    }
}
