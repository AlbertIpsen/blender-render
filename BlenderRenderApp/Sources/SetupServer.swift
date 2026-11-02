import Foundation
import Network

/// Serves the setup script on the local network while a setup window is open, so a PC can fetch it
/// with one short line. Plain HTTP, so the address carries a code that changes every time, and a few
/// wrong codes turn it off.
///
/// The same address in a browser is a page with BlenderRender PC.exe, the Windows app, which sets the
/// PC up itself: the filled-in script rides along at the end of the exe (see pc-app/Program.cs).
final class SetupServer: ObservableObject {
    @Published private(set) var command: String?
    /// "192.168.1.20/4821": the page to open in a browser on the PC.
    @Published private(set) var page: String?
    @Published private(set) var locked = false

    private static let ports: [UInt16] = [80, 8080, 8000, 8765]
    private static let wrongLimit = 5

    private let code = String(Int.random(in: 1000...9999))
    private var listener: NWListener?
    private var script = ""
    private var address = ""
    private var onPair: ((String) -> Void)?
    private var wrong = 0

    /// With `onPair`, the script reports its pairing code back here when it finishes.
    func start(script text: String, onPair: ((String) -> Void)? = nil) {
        guard listener == nil, let ip = Self.localIP() else { return }
        script = text
        self.onPair = onPair
        listen(on: Self.ports[...], ip: ip)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        command = nil
        page = nil
    }

    /// Port 80 keeps the line shortest; something else on the Mac may already have it.
    private func listen(on ports: ArraySlice<UInt16>, ip: String) {
        guard let port = ports.first, let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: .tcp, on: nwPort) else { return }
        listener = l
        l.newConnectionHandler = { [weak self] in self?.handle($0) }
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l, self.listener === l else { return }
            switch state {
            case .ready:
                self.address = ip + (port == 80 ? "" : ":\(port)")
                // Brackets rather than "| iex": the pipe is hard to find on many keyboards.
                self.command = "iex (irm \(self.address)/\(self.code))"
                self.page = "\(self.address)/\(self.code)"
            case .failed:
                l.cancel()
                self.listen(on: ports.dropFirst(), ip: ip)
            default: break
            }
        }
        l.start(queue: .main)
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: .main)
        c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { c.cancel(); return }
            // "GET /4821 HTTP/1.1"
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map { $0.dropFirst() } ?? ""
            if path == self.code {
                // PowerShell's irm doesn't ask for HTML; a browser does.
                if request.lowercased().contains("accept: text/html") {
                    self.reply(c, "200 OK", Data(self.html.utf8), type: "text/html; charset=utf-8")
                } else {
                    self.reply(c, "200 OK", Data(self.filledScript.utf8))
                }
                return
            }
            if path == self.code + "/" + Self.exeName, let exe = self.exe() {
                self.reply(c, "200 OK", exe, type: "application/octet-stream",
                           extra: "Content-Disposition: attachment; filename=\"BlenderRender PC.exe\"\r\n")
                return
            }
            // "GET /4821/pair/<code>": base64 of the PC's details, the part after BR1:.
            if path.hasPrefix(self.code + "/pair/"), let onPair = self.onPair {
                onPair("BR1:" + path.dropFirst(self.code.count + 6))
                self.reply(c, "200 OK", Data("Paired.\n".utf8))
                return
            }
            // A browser also asks for favicon.ico; only something that looks like a code counts as a guess.
            if path.count == 4, path.allSatisfy(\.isNumber) {
                self.wrong += 1
                if self.wrong >= Self.wrongLimit {
                    self.locked = true
                    self.stop()
                }
            }
            self.reply(c, "404 Not Found", Data("Check the code in BlenderRender.\n".utf8))
        }
    }

    private static let exeName = "BlenderRenderPC.exe"

    private var filledScript: String {
        let pair = onPair == nil ? "" : "http://\(address)/\(code)/pair"
        return script.replacingOccurrences(of: "__PAIR_URL__", with: pair)
            .replacingOccurrences(of: "__TRAY_URL__", with: "http://\(address)/\(code)/\(Self.exeName)")
    }

    /// The Windows app with the filled-in script after it: script, its length (4 bytes, little-endian), "BRSETUP1".
    private func exe() -> Data? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent(Self.exeName),
              var data = try? Data(contentsOf: url) else { return nil }
        let script = Data(filledScript.utf8)
        var n = UInt32(script.count).littleEndian
        data += script
        data += Data(bytes: &n, count: 4)
        data += Data("BRSETUP1".utf8)
        return data
    }

    private var html: String {
        let line = command ?? ""
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <title>BlenderRender PC</title><style>
        body{font:16px/1.5 "Segoe UI",system-ui,sans-serif;max-width:560px;margin:48px auto;padding:0 20px;color:#1c1f26}
        h1{font-size:26px;margin:0 0 4px}p{margin:10px 0}ol{padding-left:22px}li{margin:8px 0}
        a.btn{display:inline-block;background:#ff7a1a;color:#fff;text-decoration:none;font-weight:600;padding:12px 22px;border-radius:8px;margin:14px 0}
        code{background:#f0f1f4;padding:3px 7px;border-radius:5px;font-size:15px}small{color:#666}
        </style></head><body>
        <h1>BlenderRender PC</h1>
        <p>Sets this PC up to render for your Mac, then sits in the taskbar corner with an on/off switch.</p>
        <a class="btn" href="/\(code)/\(Self.exeName)">Download BlenderRender PC</a>
        <ol>
        <li>Open the download. If the browser warns that it isn't commonly downloaded, choose <b>Keep</b>.</li>
        <li>If Windows says it protected your PC, click <b>More info</b>, then <b>Run anyway</b>. The app isn't signed by a publisher Windows knows.</li>
        <li>Click <b>Set Up This PC</b> and say yes when Windows asks for permission. The Mac connects by itself when it's done.</li>
        </ol>
        <p><small>This page works while Add PC is open on the Mac. Prefer PowerShell? Run it as Administrator and type <code>\(line)</code></small></p>
        </body></html>
        """
    }

    private func reply(_ c: NWConnection, _ status: String, _ body: Data, type: String = "text/plain; charset=utf-8", extra: String = "") {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\n\(extra)Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        c.send(content: Data(head.utf8) + body, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
    }

    /// This Mac's address on the local network: Ethernet or Wi-Fi, not VPNs or link-local addresses.
    private static func localIP() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var found: [(name: String, ip: String)] = []
        var next = list
        while let a = next?.pointee {
            next = a.ifa_next
            guard let addr = a.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  a.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            let name = String(cString: a.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard name.hasPrefix("en"),
                  getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") { found.append((name, ip)) }
        }
        return found.min { $0.name.count != $1.name.count ? $0.name.count < $1.name.count : $0.name < $1.name }?.ip
    }
}
