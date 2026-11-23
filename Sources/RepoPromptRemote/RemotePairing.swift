import AVFoundation
import RepoPromptRemoteProtocol
import SwiftUI

enum RemotePairingDecoder {
    private static let maximumEncodedQRCodeBytes = 48 * 1_024
    private static let maximumPayloadBytes = 32 * 1_024
    private static let maximumIdentifierBytes = 256
    private static let maximumSecretBytes = 256
    private static let maximumAddressBytes = 256

    static func decode(_ rawValue: String, at date: Date = Date()) throws -> RemoteIrohPairingAdvertisement {
        let data = try payloadData(from: rawValue)
        guard let advertisement = try? JSONDecoder().decode(RemoteIrohPairingAdvertisement.self, from: data) else {
            throw RemotePairingError.invalidQRCode
        }
        try validateIroh(advertisement, at: date)
        return advertisement
    }

    private static func payloadData(from rawValue: String) throws -> Data {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maximumEncodedQRCodeBytes else {
            throw RemotePairingError.invalidQRCode
        }
        if let url = URL(string: trimmed), url.scheme == "rpremote",
           let payload = URLComponents(url: url, resolvingAgainstBaseURL: false)?
               .queryItems?.first(where: { $0.name == "payload" })?.value,
           let payloadData = decodeBase64URL(payload)
        {
            return try validatePayloadSize(payloadData)
        }
        if trimmed.first == "{", let directData = trimmed.data(using: .utf8) {
            return try validatePayloadSize(directData)
        }
        if let payloadData = decodeBase64URL(trimmed) {
            return try validatePayloadSize(payloadData)
        }
        throw RemotePairingError.invalidQRCode
    }

    private static func validateIroh(
        _ advertisement: RemoteIrohPairingAdvertisement,
        at date: Date
    ) throws {
        guard RemoteProtocol.supports(advertisement.protocolVersion) else {
            throw RemotePairingError.unsupportedProtocol(advertisement.protocolVersion)
        }
        guard date < advertisement.expiresAt else {
            throw RemotePairingError.expiredQRCode
        }
        guard advertisement.alpn == RemoteProtocol.irohALPN,
              isCanonicalEndpointID(advertisement.server.endpointID),
              isBoundedText(advertisement.desktopInstanceID, maximumBytes: maximumIdentifierBytes),
              isBoundedText(advertisement.oneTimeSecret, maximumBytes: maximumSecretBytes),
              advertisement.server.directAddresses.allSatisfy(isSupportedAddressText),
              let addressJSON = advertisement.server.transportAddressJSON,
              !addressJSON.isEmpty, addressJSON.utf8.count <= 16 * 1_024
        else {
            throw RemotePairingError.invalidQRCode
        }
        if let relayURL = advertisement.server.relayURL {
            guard relayURL.utf8.count <= 2_048,
                  let url = URL(string: relayURL),
                  url.scheme == "https",
                  url.host != nil
            else {
                throw RemotePairingError.invalidQRCode
            }
        }
    }

    private static func validatePayloadSize(_ data: Data) throws -> Data {
        guard data.count <= maximumPayloadBytes else {
            throw RemotePairingError.invalidQRCode
        }
        return data
    }

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func isSupportedAddressText(_ value: String) -> Bool {
        isBoundedText(value, maximumBytes: maximumAddressBytes) &&
            value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }

    private static func isCanonicalEndpointID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var normalized = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        return Data(base64Encoded: normalized)
    }
}

enum RemotePairingError: LocalizedError, Equatable {
    case invalidQRCode
    case expiredQRCode
    case unsupportedProtocol(Int)
    case unavailableDesktop

    var errorDescription: String? {
        switch self {
        case .invalidQRCode: "That QR code is not a RepoPrompt Remote pairing code."
        case .expiredQRCode: "That pairing code has expired. Generate a new code on your Mac."
        case let .unsupportedProtocol(version): "That pairing code uses unsupported protocol version \(version). Update RepoPrompt Remote and try again."
        case .unavailableDesktop: "The paired Mac is not reachable on this network."
        }
    }
}

struct PairingScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.delegate = context.coordinator
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private var didScan = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan,
                  let metadata = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = metadata.stringValue
            else { return }
            didScan = true
            onCode(value)
        }
    }
}

final class ScannerViewController: UIViewController {
    weak var delegate: AVCaptureMetadataOutputObjectsDelegate?
    var onFailure: ((String) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.repoprompt.remote.camera", qos: .userInitiated)
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isCaptureConfigured = false
    private var isRequestingAuthorization = false
    private var isVisible = false
    private var didReportFailure = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        prepareCapture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func prepareCapture() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCaptureIfNeeded()
        case .notDetermined:
            guard !isRequestingAuthorization else { return }
            isRequestingAuthorization = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isRequestingAuthorization = false
                    if granted {
                        self.configureCaptureIfNeeded()
                    } else {
                        self.reportFailure("Camera access is off. Enable it in Settings to scan a pairing code.")
                    }
                }
            }
        case .denied:
            reportFailure("Camera access is off. Enable it in Settings to scan a pairing code.")
        case .restricted:
            reportFailure("Camera access is restricted on this device.")
        @unknown default:
            reportFailure("Camera access is unavailable on this device.")
        }
    }

    private func configureCaptureIfNeeded() {
        guard !isCaptureConfigured else {
            startCaptureIfVisible()
            return
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            reportUnavailableCamera()
            return
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            reportFailure("The camera could not be opened. Check camera access in Settings and try again.")
            return
        }

        session.beginConfiguration()

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            reportFailure("The camera could not be configured for pairing.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            session.removeInput(input)
            session.commitConfiguration()
            reportFailure("QR scanning is unavailable on this device.")
            return
        }
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            session.removeOutput(output)
            session.removeInput(input)
            session.commitConfiguration()
            reportFailure("QR scanning is unavailable on this device.")
            return
        }
        output.setMetadataObjectsDelegate(delegate, queue: .main)
        output.metadataObjectTypes = [.qr]
        session.commitConfiguration()

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview
        isCaptureConfigured = true
        startCaptureIfVisible()
    }

    private func startCaptureIfVisible() {
        guard isVisible, isCaptureConfigured else { return }
        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    private func reportUnavailableCamera() {
#if DEBUG
        reportFailure("Camera is unavailable. Paste the copied pairing link below.")
#else
        reportFailure("Camera is unavailable. Pair on a device with a camera.")
#endif
    }

    private func reportFailure(_ message: String) {
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure?(message)
    }
}
