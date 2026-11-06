import AppKit
import Foundation

/// Updates are GitHub releases of the public repo, so no login is needed.
enum Updater {
    static let repo = "AlbertIpsen/blender-render"
    static let asset = "BlenderRender.zip"

    struct Release: Decodable, Equatable {
        let tagName: String
        let body: String?
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case body
        }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func checkOK(_ response: URLResponse) throws {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ShellError(message: "Couldn't reach the update server. Try again later.")
        }
    }

    static func latest() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: url)
        try checkOK(response)
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Compares dotted versions number by number, so 1.10.0 is newer than 1.9.0.
    static func isNewer(_ version: String, than current: String) -> Bool {
        let a = version.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Where the update goes: where this app is, unless that can't be replaced. Opened straight from
    /// Downloads (say), macOS runs a read-only copy (App Translocation); and the folder may not be
    /// writable. Then into Applications, or ~/Applications without admin rights.
    static var installTarget: URL {
        let fm = FileManager.default
        let me = URL(fileURLWithPath: Bundle.main.bundlePath)
        if !me.path.contains("/AppTranslocation/"), fm.isWritableFile(atPath: me.deletingLastPathComponent().path) { return me }
        if fm.isWritableFile(atPath: "/Applications") { return URL(fileURLWithPath: "/Applications/BlenderRender.app") }
        let mine = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        try? fm.createDirectory(at: mine, withIntermediateDirectories: true)
        return mine.appendingPathComponent("BlenderRender.app")
    }

    /// What the last update did, for when it didn't take (see `failedUpdate`).
    static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BlenderRender-update.log")
    }
    private static let attemptKey = "updateAttempt"

    /// After a restart: the version an update was meant to install, and what its log says, when this
    /// app still isn't that version. Asking clears it.
    static func failedUpdate() -> (version: String, why: String)? {
        guard let wanted = UserDefaults.standard.string(forKey: attemptKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: attemptKey)
        guard isNewer(wanted, than: currentVersion) else { return nil }
        let lines = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").suffix(6)
        return (wanted, lines.joined(separator: "\n"))
    }

    /// Download and check the release, then swap the app after this process quits and reopen it.
    static func install(_ release: Release) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("blenderrender-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let url = URL(string: "https://github.com/\(repo)/releases/download/\(release.tagName)/\(asset)")!
        let (download, response) = try await URLSession.shared.download(from: url)
        try checkOK(response)
        try fm.moveItem(at: download, to: tmp.appendingPathComponent(asset))
        _ = try await Shell.run("/usr/bin/ditto", ["-x", "-k", tmp.appendingPathComponent(asset).path, tmp.path])
        let new = tmp.appendingPathComponent("BlenderRender.app")
        guard Bundle(url: new)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw ShellError(message: "The downloaded update isn't BlenderRender.")
        }
        _ = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", new.path])

        // Runs on after the app quits: $1 pid, $2 new app, $3 where it goes, $4 temp folder, $5 log.
        // Every step is logged; the new app reads the log if it didn't end up the new version.
        let script = """
        exec >"$5" 2>&1
        echo "$(date) updating $3"
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3.new"
        if ditto "$2" "$3.new"; then
            xattr -dr com.apple.quarantine "$3.new" 2>/dev/null
            if rm -rf "$3" && mv "$3.new" "$3"; then echo "installed"; else echo "Couldn't replace $3"; fi
        else
            echo "Couldn't copy the update to $3"
        fi
        rm -rf "$4"
        open "$3"
        """
        let target = installTarget
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        UserDefaults.standard.set(release.version, forKey: attemptKey)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                       new.path, target.path, tmp.path, log.path]
        try p.run()
        await MainActor.run { NSApp.terminate(nil) }
    }
}
