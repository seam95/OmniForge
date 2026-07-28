import Foundation
import UserNotifications

enum MonitorNotificationError: LocalizedError {
    case authorizationDenied

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: return "Notification authorization denied"
        }
    }
}

final class UserNotificationMonitorClient: MonitorNotificationClient {
    func requestAuthorization(completion: @escaping (Result<Void, Error>) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { completion(.failure(error)); return }
            if granted { completion(.success(())); return }
            completion(.failure(MonitorNotificationError.authorizationDenied))
        }
    }

    func post(title: String, body: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        ) { error in
            if let error { completion(.failure(error)) }
            else { completion(.success(())) }
        }
    }
}
