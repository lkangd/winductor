import Foundation
import UserNotifications

// SystemNotifier.swift — 系统通知投递（票 19，spec §8.5「结束发一条系统通知」/§8.6 两段式撤销通知）。
// 生产实现：UNUserNotificationCenter（系统单例，注入 SystemNotifying 协议——单测走 fake）。
// 首次投递前请求 alert 授权（菜单栏 agent 亦可投通知；用户拒绝则静默，不阻塞恢复/撤销管线）。

public final class UserNotificationPoster: SystemNotifying {
    private let center: UNUserNotificationCenter
    private let lock = NSLock()
    private var authorizationRequested = false

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func deliver(title: String, body: String) {
        requestAuthorizationIfNeeded()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    /// 仅首投请求一次授权（.alert；拒绝/失败静默——通知是不可达的呈现增强，不是恢复语义）
    private func requestAuthorizationIfNeeded() {
        lock.lock()
        let first = !authorizationRequested
        authorizationRequested = true
        lock.unlock()
        guard first else { return }
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
}
