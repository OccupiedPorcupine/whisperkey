import Foundation

/// Bridges the WhisperKey chord gesture to the Oracle meeting app. Because
/// WhisperKey's event tap swallows the trigger key, Oracle can't observe the
/// "Caps Lock + M" chord itself — so we detect it here and fan it out as a
/// system-wide distributed notification that Oracle (a separate process)
/// listens for. If Oracle isn't running, the post is simply a no-op.
enum MeetingSignal {
    /// Must match the observer name registered in Oracle's AppDelegate.
    static let toggleName = Notification.Name("com.munyau.oracle.toggle")

    static func postToggle() {
        DistributedNotificationCenter.default().postNotificationName(
            toggleName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NSLog("WhisperKey: posted Oracle meeting toggle.")
    }
}
