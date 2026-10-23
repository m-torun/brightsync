import Foundation
import Network

/// Finds Hue bridges on the local network over Bonjour (`_hue._tcp`), whose
/// TXT record carries the bridge ID.
final class HueDiscovery {
    struct Bridge: Equatable {
        let id: String
        let host: String
    }

    private let queue: DispatchQueue
    private var browser: NWBrowser?
    private var resolving: [NWConnection] = []
    private var found: [Bridge] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Browses for `seconds`, then reports every bridge found with its IPv4
    /// address. Runs on, and completes on, the queue given at init.
    func browse(for seconds: TimeInterval, completion: @escaping ([Bridge]) -> Void) {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            for result in results {
                guard case let .bonjour(txt) = result.metadata, let id = txt["bridgeid"] else { continue }
                self?.resolve(result.endpoint, id: id)
            }
        }
        self.browser = browser
        browser.start(queue: queue)
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            browser.cancel()
            resolving.forEach { $0.cancel() }
            resolving = []
            self.browser = nil
            let bridges = found
            found = []
            completion(bridges)
        }
    }

    /// Connecting is the simplest way to turn a Bonjour service into an address.
    private func resolve(_ endpoint: NWEndpoint, id: String) {
        guard !found.contains(where: { $0.id == id }) else { return }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint,
                   case let .ipv4(address) = host,
                   !found.contains(where: { $0.id == id }) {
                    // Printing the address would add the interface ("%en0").
                    found.append(Bridge(id: id, host: address.rawValue.map(String.init).joined(separator: ".")))
                }
                connection.cancel()
            case .failed, .cancelled:
                resolving.removeAll { $0 === connection }
            default:
                break
            }
        }
        resolving.append(connection)
        connection.start(queue: queue)
    }
}
