import AppKit
import SwiftUI

/// "Set Up a Render PC" – the steps for turning a Windows PC with an NVIDIA GPU into the render PC.
/// The setup script ships inside the app, so the guide can copy or save it.
struct GuideView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @StateObject private var copied = Box(false)

    private static let scriptURL = Bundle.main.resourceURL?.appendingPathComponent("setup_windows_pc.ps1")

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set Up a Render PC").font(.title.weight(.semibold)).tracking(-0.4)
                    Text("About 10 minutes, once per PC. You'll need to be at the PC or connected to it with AnyDesk.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    step(1, "Install Blender and the NVIDIA driver", symbol: "square.and.arrow.down") {
                        Text("On the PC, install **Blender \(macBlenderVersion)** from blender.org (the same version as this Mac, so files open identically) and the latest **NVIDIA Studio or Game Ready driver**. Keep Blender's default install folder.")
                    }
                    step(2, "On this Mac: click Copy Script", symbol: "doc.on.clipboard") {
                        Text("That's all for this step. The setup script is now on your Mac's clipboard, and AnyDesk shares the clipboard with the PC, so you can paste it there in step 3. Not using AnyDesk? Choose **Save as File…** and move the file to the PC with a USB stick.")
                        HStack(spacing: 8) {
                            Button { copyScript() } label: {
                                Label(copied.value ? "Copied" : "Copy Script", systemImage: copied.value ? "checkmark" : "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Save as File…") { saveScript() }
                        }
                        .padding(.top, 4)
                        .disabled(Self.scriptURL == nil)
                    }
                    step(3, "On the PC: paste it into PowerShell", symbol: "terminal") {
                        Text("1. Click **Start**, type **PowerShell**, right-click **Windows PowerShell** and choose **Run as administrator**.\n2. Click **Yes** on the Windows prompt. Over AnyDesk it may only show on the PC's own screen.\n3. **Right-click** once inside the blue window to paste, then press **Return**. If the lines start with **>>**, press **Return** once more; that's PowerShell waiting for the end of the script.\n4. Wait for **== Done. Send these back:** and note the lines below it.")
                        Text("The script turns on Windows' built-in SSH server, lets this Mac sign in with its key (no password) and installs the render queue. If you saved the file instead, run this in the folder you put it in:").padding(.top, 2)
                        code("powershell -ExecutionPolicy Bypass -File setup_windows_pc.ps1")
                    }
                    step(4, "Enter the PC's details here", symbol: "gearshape") {
                        Text("When the script finishes it prints **WIN_HOST** (the PC's address) and **WIN_USER**. Put them in Settings and choose **Save & Connect**. BlenderRender copies the queue scripts to the PC by itself.")
                        Button("Open Settings…") { openSettings() }.padding(.top, 4)
                    }
                    step(5, "Keep the PC ready", symbol: "bolt.horizontal.circle", last: true) {
                        Text("Renders run while the PC is **on, awake and logged in**. In Windows Settings › System › Power, set sleep to **Never** when plugged in. In your router, give the PC a **fixed (reserved) IP address** so the address in Settings keeps working.")
                    }

                    troubleshooting
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 600, height: 440)
    }

    private var macBlenderVersion: String {
        // "/Applications/Blender.app/Contents/MacOS/Blender" -> read the app's version, falls back to "5.2"
        let app = URL(fileURLWithPath: state.cfg.macBlender).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return v.map { $0.split(separator: ".").prefix(2).joined(separator: ".") } ?? "5.2"
    }

    private func step<Content: View>(_ n: Int, _ title: String, symbol: String, last: Bool = false,
                                      @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Text("\(n)")
                    .font(.callout.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor))
                if !last {
                    Rectangle().fill(Color.accentColor.opacity(0.25)).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol).font(.headline).labelStyle(.titleOnly)
                content().font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, last ? 8 : 22)
            .padding(.top, 3)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced)).foregroundStyle(.primary).textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
    }

    private var troubleshooting: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("If it shows Offline").font(.headline)
            tip("The PC is asleep, off or logged out", "Wake it and log in; the queue starts with your login.")
            tip("The address changed", "Check the PC's current IP (run `ipconfig` on the PC), update Settings, then reserve that address in the router.")
            tip("SSH isn't running", "In PowerShell on the PC: `Get-Service sshd`. If it's stopped, run the setup script again; running it twice is safe.")
            tip("A different network profile", "The firewall rule allows Private networks. In Windows Settings › Network, set the PC's network to Private.")
            tip("A render fails right away", "Open the job's Blender log (hover the row). A different Blender version on the PC is the usual cause.")
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .padding(.top, 8)
    }

    private func tip(_ problem: String, _ fix: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(problem).font(.callout.weight(.medium))
            Text(.init(fix)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The setup script with this Mac's public key filled in; creates a key if the Mac has none.
    /// The app signs in non-interactively, so a new key has no passphrase.
    private func scriptWithKey() -> String? {
        guard let url = Self.scriptURL, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let ssh = NSHomeDirectory() + "/.ssh"
        let fm = FileManager.default
        if !fm.fileExists(atPath: ssh + "/id_ed25519") {
            try? fm.createDirectory(atPath: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            p.arguments = ["-t", "ed25519", "-N", "", "-q", "-f", ssh + "/id_ed25519"]
            try? p.run()
            p.waitUntilExit()
        }
        guard let key = try? String(contentsOfFile: ssh + "/id_ed25519.pub", encoding: .utf8) else {
            state.alert = "Couldn't read this Mac's SSH key at ~/.ssh/id_ed25519.pub."
            return nil
        }
        return text.replacingOccurrences(of: "__MAC_PUBLIC_KEY__", with: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func copyScript() {
        guard let text = scriptWithKey() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.ui) { copied.value = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.ui) { copied.value = false } }
    }

    private func saveScript() {
        guard let text = scriptWithKey() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "setup_windows_pc.ps1"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let dst = panel.url {
            try? text.write(to: dst, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        }
    }
}
