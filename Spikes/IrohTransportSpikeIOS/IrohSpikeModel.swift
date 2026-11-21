import Foundation
import RepoPromptIrohTransport
import Security

@MainActor
final class IrohSpikeModel: ObservableObject {
    @Published var secretHex = ""
    @Published var relayEnabled = true
    @Published var endpointID = "Not started"
    @Published var addressJSON = ""
    @Published var remoteAddressJSON = ""
    @Published var message = "opaque iOS echo"
    @Published var messageCount = "1"
    @Published var pathSummary = "Not connected"
    @Published var status = "Idle"
    @Published var running = false

    private var endpoint: TransportEndpoint?
    private var connection: TransportConnection?
    private var acceptTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lifecycleToken: UInt64 = 0
    private var didAttemptSimulatorGate = false
    private var simulatorGateEvidenceURL: URL?

    init() {
        generateSecret()
    }

    func generateSecret() {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard result == errSecSuccess else {
            status = "SecRandomCopyBytes failed"
            return
        }
        secretHex = Data(bytes).spikeHex
        status = "Generated an in-memory test secret (not persisted)"
    }

    func start() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        let previousEndpoint = detachEndpointState()
        if let previousEndpoint {
            try? await previousEndpoint.shutdown()
        }
        guard lifecycleToken == token else { return }

        var createdEndpoint: TransportEndpoint?
        do {
            generation &+= 1
            let newEndpoint = try await RepoPromptIrohSpike.start(
                secret: Data(spikeHex: secretHex),
                relayEnabled: relayEnabled,
                generation: generation
            )
            createdEndpoint = newEndpoint
            let snapshot: EndpointSnapshot
            if relayEnabled {
                status = "Waiting for relay registration…"
                snapshot = try await newEndpoint.waitUntilOnline(timeoutMillis: 30_000)
            } else {
                snapshot = try newEndpoint.snapshot()
            }
            guard lifecycleToken == token else {
                try? await newEndpoint.shutdown()
                return
            }
            endpoint = newEndpoint
            endpointID = snapshot.endpointId
            addressJSON = snapshot.addressJson
            running = true
            status = "Endpoint started; address is ready to copy"
            acceptTask = Task { [weak self] in
                await self?.acceptLoop(endpoint: newEndpoint, generation: snapshot.generation)
            }
        } catch {
            if let createdEndpoint {
                try? await createdEndpoint.shutdown()
            }
            guard lifecycleToken == token else { return }
            status = "Start failed: \(error.localizedDescription)"
        }
    }

    func runSimulatorGateIfRequested() async {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.arguments.contains("--simulator-gate-listen") else { return }
        guard !didAttemptSimulatorGate else { return }
        didAttemptSimulatorGate = true

        let evidenceURL = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("iroh-simulator-gate.json")
        simulatorGateEvidenceURL = evidenceURL
        try? FileManager.default.removeItem(at: evidenceURL)
        relayEnabled = false
        await start()
        writeSimulatorGateEvidence(phase: running ? "ready" : "start_failed")
        #endif
    }

    func connect() async {
        guard let endpoint else {
            status = "Start this endpoint first"
            return
        }
        let token = lifecycleToken
        do {
            let newConnection = try await endpoint.connect(
                addressJson: remoteAddressJSON,
                alpn: RepoPromptIrohSpike.alpn
            )
            guard lifecycleToken == token, self.endpoint === endpoint else {
                newConnection.close()
                return
            }
            connection = newConnection
            pathSummary = newConnection.pathSummary()
            status = "Connected to \(newConnection.peerEndpointId())"
        } catch {
            guard lifecycleToken == token else { return }
            status = "Connect failed: \(error.localizedDescription)"
        }
    }

    func sendEchoes() async {
        guard let connection else {
            status = "Connect first"
            return
        }
        guard let count = Int(messageCount), count > 0, count <= 10_000 else {
            status = "Message count must be 1…10000"
            return
        }
        do {
            status = "Sending \(count) framed messages…"
            for sequence in 0 ..< count {
                let payload = Data("\(message)-\(sequence)".utf8)
                let echoed = try await connection.sendFrame(payload: payload)
                guard echoed == payload else {
                    throw IrohSpikeUIError.echoMismatch(sequence)
                }
            }
            pathSummary = connection.pathSummary()
            status = "ECHO_OK messages=\(count)"
        } catch {
            status = "Echo failed: \(error.localizedDescription)"
        }
    }

    func verifyOversizedFrame() async {
        guard let connection else {
            status = "Connect first"
            return
        }
        do {
            _ = try await connection.sendFrame(
                payload: Data(count: RepoPromptIrohSpike.maximumFrameBytes + 1)
            )
            status = "FAILED: oversized frame was accepted"
        } catch {
            status = "Oversized frame rejected: \(error.localizedDescription)"
        }
    }

    func refreshDiagnostics() {
        pathSummary = connection?.pathSummary() ?? "Not connected"
        if let endpoint, let snapshot = try? endpoint.snapshot() {
            endpointID = snapshot.endpointId
            addressJSON = snapshot.addressJson
        }
    }

    func stop() async {
        lifecycleToken &+= 1
        let token = lifecycleToken
        let endpoint = detachEndpointState()
        if let endpoint {
            try? await endpoint.shutdown()
        }
        guard lifecycleToken == token else { return }
        if endpointID != "Not started" {
            status = "Stopped; the test secret remains only in this view's memory"
        }
    }

    private func detachEndpointState() -> TransportEndpoint? {
        acceptTask?.cancel()
        acceptTask = nil
        connection?.close()
        connection = nil
        let detachedEndpoint = endpoint
        endpoint = nil
        running = false
        pathSummary = "Not connected"
        return detachedEndpoint
    }

    private func acceptLoop(endpoint: TransportEndpoint, generation: UInt64) async {
        while !Task.isCancelled {
            do {
                let incoming = try await endpoint.accept()
                guard incoming.generation == generation else { continue }
                status = "Accepted \(incoming.peerEndpointId) via \(incoming.pathSummary)"
                writeSimulatorGateEvidence(
                    phase: "accepted",
                    peerEndpointID: incoming.peerEndpointId,
                    acceptedPath: incoming.pathSummary
                )
            } catch {
                if !Task.isCancelled {
                    status = "Accept stopped: \(error.localizedDescription)"
                }
                return
            }
        }
    }

    private func writeSimulatorGateEvidence(
        phase: String,
        peerEndpointID: String? = nil,
        acceptedPath: String? = nil
    ) {
        guard let simulatorGateEvidenceURL else { return }
        let evidence = SimulatorGateEvidence(
            phase: phase,
            endpointID: endpointID == "Not started" ? nil : endpointID,
            addressJSON: addressJSON.isEmpty ? nil : addressJSON,
            peerEndpointID: peerEndpointID,
            acceptedPath: acceptedPath,
            error: phase == "start_failed" ? status : nil
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(evidence).write(to: simulatorGateEvidenceURL, options: .atomic)
        } catch {
            status = "Could not write public Simulator gate evidence: \(error.localizedDescription)"
        }
    }
}

private struct SimulatorGateEvidence: Codable {
    let phase: String
    let endpointID: String?
    let addressJSON: String?
    let peerEndpointID: String?
    let acceptedPath: String?
    let error: String?
}

private enum IrohSpikeUIError: Error, LocalizedError {
    case echoMismatch(Int)

    var errorDescription: String? {
        switch self {
        case let .echoMismatch(sequence): "Echo mismatch at sequence \(sequence)."
        }
    }
}
