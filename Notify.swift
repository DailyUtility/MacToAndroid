// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Waldron
// 操作完成通知
//
// 为什么需要：菜单点击后会立刻关闭，异步操作（allow 要等客户端真的连上，可能几秒）
// 完成时界面已经不在眼前了，用户得不到任何确认。图标和悬停提示虽然会更新，
// 但那需要用户主动去看。
//
// 用 UNUserNotificationCenter，前提是 bundle 必须有 CFBundleIdentifier——
// 没有的话应用无法被注册为通知发送者，通知会被系统**静默丢弃**，不报任何错。

import Foundation
import UserNotifications

enum Notify {
    private static var asked = false
    private static let presenter = ForegroundPresenter()

    /// 首次使用时请求权限。系统只会弹一次授权框。
    static func prepare() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().delegate = presenter
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ title: String, _ body: String) {
        prepare()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        // 用固定前缀 + 时间戳做 identifier，避免同类通知互相覆盖
        let id = "mta-\(Int(Date().timeIntervalSince1970 * 1000))"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: c, trigger: nil),
            withCompletionHandler: nil)
    }
}

/// 应用处于前台（例如主窗口或弹窗开着）时，系统默认**不显示**本应用的通知。
/// 不设代理的话，用户在窗口里点了操作，完成通知就被吞掉了
private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
