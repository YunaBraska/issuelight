import Foundation
import CoreFoundation

public enum IssueNavigationURL {
    public static func ssh(
        for issue: MonitoringIssue,
        configuration: RemoteLoginConfiguration
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "ssh"
        components.host = issue.hostName
        components.port = configuration.port
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        components.user = username.isEmpty ? nil : username
        return components.url
    }

    public static func rdp(
        for issue: MonitoringIssue,
        configuration: RemoteLoginConfiguration
    ) -> URL? {
        let username = configuration.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = "\(issue.hostName):\(configuration.port)"
            .addingPercentEncoding(withAllowedCharacters: rdpAttributeValueCharacters) else {
            return nil
        }
        var value = "rdp://full%20address=s:\(address)"
        if !username.isEmpty {
            guard let encodedUsername = username
                .addingPercentEncoding(withAllowedCharacters: rdpAttributeValueCharacters) else {
                return nil
            }
            value += "&username=s:\(encodedUsername)"
        }
        let bytes = Array(value.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress,
                  let url = CFURLCreateWithBytes(
                    nil,
                    baseAddress,
                    buffer.count,
                    CFStringBuiltInEncodings.UTF8.rawValue,
                    nil
                  ) else {
                return nil
            }
            return url as URL
        }
    }

    private static let rdpAttributeValueCharacters: CharacterSet = {
        var characters = CharacterSet.urlQueryAllowed
        characters.remove(charactersIn: "%&=;#?")
        return characters
    }()
}
