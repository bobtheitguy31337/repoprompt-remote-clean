import Foundation

final class RemoteBonjourDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private let onService: (String, Int, String?) -> Void
    private let onError: (Error) -> Void

    init(onService: @escaping (String, Int, String?) -> Void, onError: @escaping (Error) -> Void) {
        self.onService = onService
        self.onError = onError
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_repoprompt-remote._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.removeAll()
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName, sender.port > 0 else { return }
        let txtRecord = NetService.dictionary(fromTXTRecord: sender.txtRecordData() ?? Data())
        let desktopInstanceID = txtRecord["desktopInstanceID"]
            .flatMap { String(data: $0, encoding: .utf8) }
        onService(host, sender.port, desktopInstanceID)
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        onError(NSError(domain: "RepoPromptRemoteBonjour", code: 1, userInfo: errorDict))
    }
}
