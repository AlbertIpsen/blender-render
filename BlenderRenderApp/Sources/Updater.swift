import AppKit
import Foundation

/// Updates are GitHub releases of a private repo, so they go through the gh CLI and its login.
enum Updater {
    static let repo = "AlbertIpsen/blender-render"
    static let asset = "BlenderRender.zip"

    struct Release: Decodable, Equatable {
        let tagName: String
        let body: String?
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static func gh() throws -> String {
        let found = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let found else {
            throw ShellError(message: "Updates need the GitHub CLI. Install it with: brew install gh, then run: gh auth login")
        }
        return found
    }

    static func latest() async throws -> Release {
        let data = try await Shell.run(try gh(), ["release", "view", "--repo", repo, "--json", "tagName,body"])
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

    /// Download and check the release, then swap the app after this process quits and reopen it.
    static func install(_ release: Release) async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("blenderrender-update-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        _ = try await Shell.run(try gh(), ["release", "download", release.tagName, "--repo", repo,
                                           "--pattern", asset, "--dir", tmp.path])
        _ = try await Shell.run("/usr/bin/ditto", ["-x", "-k", tmp.appendingPathComponent(asset).path, tmp.path])
        let new = tmp.appendingPathComponent("BlenderRender.app")
        guard Bundle(url: new)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw ShellError(message: "The downloaded update isn't BlenderRender.")
        }
        _ = try await Shell.run("/usr/bin/codesign", ["--verify", "--deep", new.path])

        // Runs on after the app quits: $1 pid, $2 new app, $3 installed app, $4 temp folder.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        ditto "$2" "$3.new" && xattr -dr com.apple.quarantine "$3.new" 2>/dev/null
        if [ -d "$3.new" ]; then rm -rf "$3" && mv "$3.new" "$3"; fi
        rm -rf "$4"
        open "$3"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier),
                       new.path, Bundle.main.bundlePath, tmp.path]
        try p.run()
        await MainActor.run { NSApp.terminate(nil) }
    }
}
