import Foundation

/// A BlenderRender computer heard on the local network (rqnet.py says who it is every 5 seconds).
struct Nearby: Identifiable, Equatable {
    let id: String
    var name: String
    var kind: String
    var host: String
    var port: Int
    /// Takes render jobs from other computers right now.
    var allow: Bool
    var rendering: Bool
    var gpu: String
    var blender: String
    var version: Int
    var seen: Date

    var isMac: Bool { kind == "mac" }
    /// "RTX 4090" from Cycles' "OPTIX ['NVIDIA GeForce RTX 4090']".
    var gpuName: String {
        guard let open = gpu.firstIndex(of: "'"), let close = gpu[gpu.index(after: open)...].firstIndex(of: "'") else { return gpu }
        return String(gpu[gpu.index(after: open)..<close]).replacingOccurrences(of: "NVIDIA GeForce ", with: "")
    }
}

/// Listens for rqnet.py's announcements on UDP 48210 and calls back on the main actor.
final class Discovery: @unchecked Sendable {
    static let port: UInt16 = 48210
    private let onHear: @MainActor (Nearby) -> Void
    private var fd: Int32 = -1

    init(onHear: @escaping @MainActor (Nearby) -> Void) { self.onHear = onHear }

    func start() {
        guard fd < 0 else { return }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, socklen_t(MemoryLayout<Int32>.size))  // This Mac's rqnet.py may listen too
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); fd = -1; return }
        let fd = self.fd
        Thread.detachNewThread { [onHear] in
            var buf = [UInt8](repeating: 0, count: 65536)
            while true {
                var from = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
                }
                if n < 0 { if errno == EINTR { continue } else { return } }
                guard let n = Optional(n), n > 0, let msg = Self.parse(Data(buf[0..<n]), from: from) else { continue }
                Task { @MainActor in onHear(msg) }
            }
        }
    }

    private static func parse(_ data: Data, from: sockaddr_in) -> Nearby? {
        struct Beacon: Decodable {
            let br: Int; let id: String; let name: String; let kind: String; let port: Int; let allow: Bool
            let rendering: Bool?; let gpu: String?; let blender: String?; let version: Int?
        }
        guard let b = try? JSONDecoder().decode(Beacon.self, from: data), b.br == 1 else { return nil }
        var a = from.sin_addr
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &a, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return Nearby(id: b.id, name: b.name, kind: b.kind, host: String(cString: text), port: b.port, allow: b.allow,
                      rendering: b.rendering ?? false, gpu: b.gpu ?? "", blender: b.blender ?? "", version: b.version ?? 0,
                      seen: Date())
    }
}
