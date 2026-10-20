import Foundation
import Network

/// The device's network as the link cares about it: whether there is one, and which (the interfaces it goes through,
/// in order of preference, and their gateways). A change of either is a change of network: Wi-Fi back after airplane
/// mode, Wi-Fi to cellular, another Wi-Fi.
public struct NetworkPath: Sendable, Equatable, CustomStringConvertible {
    public var available: Bool
    public var interfaces: [String]

    public init(available: Bool, interfaces: [String] = []) {
        self.available = available
        self.interfaces = interfaces
    }

    init(_ path: NWPath) {
        available = path.status == .satisfied || path.status == .requiresConnection
        interfaces = path.availableInterfaces.map { "\($0.name) (\($0.type))" } + path.gateways.map { "via \($0)" }
    }

    public var description: String {
        available ? interfaces.isEmpty ? "available" : interfaces.joined(separator: ", ") : "none"
    }
}

/// Follows the device's network (NWPathMonitor): its first report, then each change.
final class NetworkMonitor: @unchecked Sendable {
    let paths: AsyncStream<NetworkPath>
    private let sink: AsyncStream<NetworkPath>.Continuation
    private let monitor = NWPathMonitor()

    init() {
        (paths, sink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        monitor.pathUpdateHandler = { [sink] path in sink.yield(NetworkPath(path)) }
        monitor.start(queue: QUIC.queue)
    }

    func stop() {
        monitor.cancel()
        sink.finish()
    }
}
