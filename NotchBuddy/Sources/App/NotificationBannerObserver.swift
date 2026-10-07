import Foundation
import AppKit
import ApplicationServices

// MARK: - Notification Banner Observer
// Monitors macOS Notification Center banners using Accessibility API (AXUIElement).
// Captures new notifications in real-time from Mail, Messages, Slack, Banking, Calendar, etc.
@MainActor
public final class NotificationBannerObserver: ObservableObject {
    public static let shared = NotificationBannerObserver()

    private var isRunning = false
    private var pollTimer: Timer?
    private var lastSeenBannerText: String = ""

    private init() {}

    func start(state: AppState) {
        guard !isRunning else { return }
        isRunning = true

        logSentinel("NotificationBannerObserver started (monitoring macOS system banners)")

        // Poll Notification Center UI every 1.2 seconds for active banners
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.inspectNotificationBanners(state: state)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    public func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        isRunning = false
    }

    private func inspectNotificationBanners(state: AppState) {
        // Find Notification Center UI process
        let apps = NSWorkspace.shared.runningApplications
        guard let notifApp = apps.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui" ||
            $0.bundleIdentifier == "com.apple.systemuiserver" ||
            $0.localizedName == "Notification Center" ||
            $0.localizedName == "NotificationCenter"
        }) else {
            return
        }

        let pid = notifApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return
        }

        for window in windows {
            var titleRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
            let winTitle = (titleRef as? String) ?? ""

            // Extract text nodes from banner window
            let extractedTexts = extractTextValues(from: window, maxDepth: 4)
            guard !extractedTexts.isEmpty else { continue }

            // Typical macOS notification banner layout has:
            // [0]: App Name (e.g. "Mail", "Slack", "Bank")
            // [1]: Title (e.g. "Hóa đơn điện tử EVN", "Alice")
            // [2+]: Body / Content
            let compositeKey = extractedTexts.joined(separator: " | ")
            guard compositeKey != lastSeenBannerText else { continue }
            lastSeenBannerText = compositeKey

            let appName = extractedTexts.first ?? winTitle
            let title = extractedTexts.count > 1 ? extractedTexts[1] : (winTitle.isEmpty ? "Thông báo mới" : winTitle)
            let body = extractedTexts.count > 2 ? extractedTexts.dropFirst(2).joined(separator: "\n") : ""

            let event = InputEvent(
                source: .notificationBanner,
                appName: appName.isEmpty ? "macOS" : appName,
                title: title,
                content: body,
                metadata: ["rawBanner": compositeKey]
            )

            ProactiveEventBus.shared.ingest(event: event, state: state)
            break
        }
    }

    private func extractTextValues(from element: AXUIElement, maxDepth: Int) -> [String] {
        guard maxDepth > 0 else { return [] }
        var result: [String] = []

        var valRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef) == .success,
           let str = valRef as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(str.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success,
           let str = titleRef as? String, !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !result.contains(str) {
                result.append(str.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children.prefix(10) {
                let sub = extractTextValues(from: child, maxDepth: maxDepth - 1)
                for item in sub where !result.contains(item) {
                    result.append(item)
                }
            }
        }

        return result
    }
}
