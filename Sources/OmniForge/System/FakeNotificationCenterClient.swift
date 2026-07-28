import Foundation

final class FakeNotificationCenterClient: NotificationCenterClient {
    private var blocks: [ObjectIdentifier: () -> Void] = [:]
    private var nameToTokens: [Notification.Name: [ObjectIdentifier]] = [:]

    func addObserver(forName name: Notification.Name, using block: @escaping () -> Void) -> AnyObject {
        let token = NSObject()
        let id = ObjectIdentifier(token)
        blocks[id] = block
        nameToTokens[name, default: []].append(id)
        return token
    }

    func removeObserver(_ token: AnyObject) {
        let id = ObjectIdentifier(token)
        blocks[id] = nil
        for (name, tokens) in nameToTokens {
            nameToTokens[name] = tokens.filter { $0 != id }
        }
    }

    func post(name: Notification.Name) {
        let tokens = nameToTokens[name] ?? []
        for token in tokens {
            blocks[token]?()
        }
    }
}
