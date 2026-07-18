import CoreFoundation

public enum StateChangeNotifier {
    public static let notificationName = "com.agentglance.stateChanged"

    public static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notificationName as CFString),
            nil,
            nil,
            true
        )
    }
}
