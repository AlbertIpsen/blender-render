import AppKit
import SwiftUI

/// The setup script that ships in the app.
enum SetupScript {
    static let url = Bundle.main.resourceURL?.appendingPathComponent("setup_windows_pc.ps1")
    static let keyProblem = "Couldn't read this Mac's SSH key at ~/.ssh/id_ed25519.pub."

    /// The script with this Mac's public key filled in; creates a key if the Mac has none.
    /// The app signs in non-interactively, so a new key has no passphrase.
    static func withKey() -> String? {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
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
        guard let key = try? String(contentsOfFile: ssh + "/id_ed25519.pub", encoding: .utf8) else { return nil }
        return text.replacingOccurrences(of: "__MAC_PUBLIC_KEY__", with: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// The address of this Mac's setup page (BlenderRender PC.exe), with the PowerShell line as the
/// alternative. Works while the view is on screen.
struct SetupCommand: View {
    @StateObject private var server = SetupServer()
    var onPair: ((String) -> Void)?
    var isLive: Binding<Bool>?

    var body: some View {
        Group {
            if let command = server.command, let page = server.page {
                VStack(alignment: .leading, spacing: 6) {
                    Text(page)
                        .font(.system(.title2, design: .monospaced).weight(.semibold)).foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    Text("Or in PowerShell as Administrator: ").foregroundStyle(.secondary)
                        + Text(command).font(.system(.callout, design: .monospaced))
                }
                .textSelection(.enabled)
            } else if server.locked {
                Text("Too many wrong codes, so this link was turned off. Close this window and open it again for a new one.")
                    .foregroundStyle(.red)
            } else {
                Text("The short link isn't available. Is this Mac on a network? Copy Script still works.")
            }
        }
        .onAppear { if let script = SetupScript.withKey() { server.start(script: script, onPair: onPair) } }
        .onDisappear { server.stop() }
        .onChange(of: server.command) { isLive?.wrappedValue = server.command != nil }
    }
}

/// Add PC: the computers with BlenderRender on this network, each with an Add button.
struct AddPCView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    let add: (PCEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Render Computer").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for computers with BlenderRender on this network…").foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                if state.nearbyToAdd.isEmpty {
                    Text("None yet").foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 60)
                }
                ForEach(state.nearbyToAdd) { n in
                    NearbyRow(n: n) { add(PCEntry(n)) }
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            .animation(.default, value: state.nearbyToAdd)
            Text("Not listed? On a PC, install BlenderRender PC and click Set Up This PC. On a Mac, open BlenderRender and switch on Allow this computer to do render jobs.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Setup Guide") { state.showGuide = true; dismiss() }.buttonStyle(.link)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// "Set Up a Render PC" – the steps for turning a Windows PC with an NVIDIA GPU into the render PC.
/// The setup script ships inside the app, so the guide can copy or save it.
struct GuideView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @StateObject private var copied = Box(false)

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
                    step(2, "On the PC: download BlenderRender PC", symbol: "arrow.down.circle") {
                        Text("Open this address in a browser on the PC. It always gets the latest version.")
                        code(Self.downloadURL)
                        Text("Or, while this guide is open, the address below serves it from this Mac (the same network only).").padding(.top, 4)
                        SetupCommand()
                    }
                    step(3, "Run it and click Set Up This PC", symbol: "play.circle") {
                        Text("If the browser says the file isn't commonly downloaded, choose **Keep**. If Windows says it protected your PC, click **More info**, then **Run anyway**. Then click **Set Up This PC** and **Yes** when Windows asks; over AnyDesk that prompt may only show on the PC's own screen. BlenderRender PC then starts with Windows and keeps itself up to date.")
                    }
                    step(4, "Add it here", symbol: "plus.circle") {
                        Text("The PC shows up on this Mac under **On This Network**, in Settings and in the Render PCs panel. Click **Add**. Other Macs with BlenderRender can add it too.")
                        Button("Open Settings…") { openSettings() }.padding(.top, 4)
                        Text("No network between the Mac and the PC? **Copy Script** and paste it into an administrator PowerShell on the PC (AnyDesk shares the clipboard), or **Save as File…**; it sets the PC up over SSH and prints a pairing code under **Main PC** in Settings › Advanced.").padding(.top, 8)
                        HStack(spacing: 8) {
                            Button { copyScript() } label: {
                                Label(copied.value ? "Copied" : "Copy Script", systemImage: copied.value ? "checkmark" : "doc.on.doc")
                            }
                            Button("Save as File…") { saveScript() }
                        }
                        .padding(.top, 4)
                        .disabled(SetupScript.url == nil)
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

    static let downloadURL = "github.com/AlbertIpsen/blender-render/releases/latest/download/BlenderRenderPC.exe"

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
            tip("It doesn't show up under On This Network", "Check BlenderRender PC is running on the PC (the icon in the taskbar corner) and both are on the same network. A Mac shows up once BlenderRender is open on it.")
            tip("SSH isn't running (a PC added by address)", "In PowerShell on the PC: `Get-Service sshd`. If it's stopped, run the setup script again; running it twice is safe.")
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

    private func copyScript() {
        guard let text = SetupScript.withKey() else { state.alert = SetupScript.keyProblem; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.ui) { copied.value = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { withAnimation(.ui) { copied.value = false } }
    }

    private func saveScript() {
        guard let text = SetupScript.withKey() else { state.alert = SetupScript.keyProblem; return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "setup_windows_pc.ps1"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let dst = panel.url {
            try? text.write(to: dst, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([dst])
        }
    }
}
