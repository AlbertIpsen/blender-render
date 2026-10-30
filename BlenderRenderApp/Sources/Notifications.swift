import AppKit
import UserNotifications

/// Native notifications for finished and failed renders: the app's own icon, the job name as title,
/// a thumbnail of the render, and Download / Show Log buttons right in the banner.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    private enum ID {
        static let doneCategory = "render.done"
        static let failedCategory = "render.failed"
        static let download = "download"
        static let showLog = "showLog"
    }

    /// Called on the main actor when a notification button (or the banner itself) is clicked.
    var onAction: (@MainActor (_ jobID: String, _ action: String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: ID.doneCategory,
                                   actions: [UNNotificationAction(identifier: ID.download, title: "Download",
                                                                  options: [.foreground])],
                                   intentIdentifiers: []),
            UNNotificationCategory(identifier: ID.failedCategory,
                                   actions: [UNNotificationAction(identifier: ID.showLog, title: "Show Log",
                                                                  options: [.foreground])],
                                   intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func renderDone(_ job: PCJob, gpu: String, preview: URL?) {
        let c = UNMutableNotificationContent()
        c.title = job.displayName
        c.subtitle = "Ready to download"
        var body = job.outputSummary
        if let s = job.started, let e = job.ended { body += " · rendered in " + JobRow.duration(Int(e - s)) }
        if !gpu.isEmpty { body += " on " + Notifier.prettyGPU(gpu) }
        c.body = body
        c.sound = UNNotificationSound(named: UNNotificationSoundName("Glass"))
        c.categoryIdentifier = ID.doneCategory
        c.threadIdentifier = "renders"
        c.userInfo = ["job": job.id]
        if let preview, let a = try? UNNotificationAttachment(identifier: "preview", url: preview, options: nil) {
            c.attachments = [a]
        }
        post(c, id: job.id)
    }

    func renderFailed(_ job: PCJob) {
        let c = UNMutableNotificationContent()
        c.title = job.displayName
        c.subtitle = "Render failed"
        c.body = job.error ?? "Open the Blender log to see what went wrong."
        if (job.files ?? 0) > 0 { c.body += " Partial results can be downloaded." }
        c.sound = UNNotificationSound(named: UNNotificationSoundName("Basso"))
        c.categoryIdentifier = ID.failedCategory
        c.threadIdentifier = "renders"
        c.userInfo = ["job": job.id]
        post(c, id: job.id)
    }

    private func post(_ content: UNNotificationContent, id: String) {
        center.add(UNNotificationRequest(identifier: "job-\(id)", content: content, trigger: nil))
    }

    // Show banners even while BlenderRender is the frontmost app.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let job = response.notification.request.content.userInfo["job"] as? String ?? ""
        let action = response.actionIdentifier
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            self.onAction?(job, action)
            completionHandler()
        }
    }

    /// "OPTIX ['NVIDIA GeForce RTX 2060 SUPER']" -> "RTX 2060 SUPER"
    static func prettyGPU(_ raw: String) -> String {
        var name = raw
        if let a = raw.firstIndex(of: "'"), let b = raw[raw.index(after: a)...].firstIndex(of: "'") {
            name = String(raw[raw.index(after: a)..<b])
        }
        for prefix in ["NVIDIA GeForce ", "NVIDIA "] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
        return name
    }

    static let downloadAction = ID.download
    static let showLogAction = ID.showLog
}
