import Foundation
import Network

/// Serves the setup script on the local network while a setup window is open, so a PC can fetch it
/// with one short line. Plain HTTP, so the address carries a code that changes every time, and a few
/// wrong codes turn it off.
final class SetupServer: ObservableObject {
    @Published private(set) var command: String?
    @Published private(set) var locked = false

    private static let ports: [UInt16] = [80, 8080, 8000, 8765]
    private static let wrongLimit = 5

    private let code = String(Int.random(in: 1000...9999))
    private var listener: NWListener?
    private var script = Data()
    private var wrong = 0

    func start(script text: String) {
        guard listener == nil, let ip = Self.localIP() else { return }
        script = Data(text.utf8)
        listen(on: Self.ports[...], ip: ip)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        command = nil
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
                // Brackets rather than "| iex": the pipe is hard to find on many keyboards.
                self.command = "iex (irm \(ip)\(port == 80 ? "" : ":\(port)")/\(self.code))"
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
                self.reply(c, "200 OK", self.script)
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

    private func reply(_ c: NWConnection, _ status: String, _ body: Data) {
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
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
