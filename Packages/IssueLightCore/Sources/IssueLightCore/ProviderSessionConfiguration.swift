import Foundation
import Network

extension URLSessionConfiguration {
    func routed(through proxy: ProviderSOCKSProxy?) -> URLSessionConfiguration {
        let value = copy() as! URLSessionConfiguration
        guard let proxy else { return value }
        if #available(macOS 14.0, *),
           (1...65_535).contains(proxy.port),
           let port = NWEndpoint.Port(rawValue: UInt16(proxy.port)) {
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(proxy.host),
                port: port
            )
            value.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        }
        return value
    }
}
