import Foundation

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Thread-safe byte buffer for pipe readers.
final class LockedData: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}

enum Shell {
    /// Run a program and return its stdout. `stdinFile` is streamed in; `stdoutFile` receives stdout
    /// instead of memory (for large downloads). `progress` gets the bytes sent (stdin) or received (stdoutFile).
    static func run(_ exe: String, _ args: [String], stdinFile: URL? = nil, stdoutFile: URL? = nil,
                    progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            let out = LockedData(), err = LockedData()
            let outFile: FileHandle? = stdoutFile.flatMap { f in
                FileManager.default.createFile(atPath: f.path, contents: nil)
                return try? FileHandle(forWritingTo: f)
            }
            if let f = stdoutFile, outFile == nil {
                cont.resume(throwing: ShellError(message: "Can't write \(f.path)")); return
            }
            let reader = DispatchGroup()  // the stdout-to-file copy, finished before we return
            p.standardOutput = outPipe
            if stdoutFile == nil {
                outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
            }
            p.standardError = errPipe
            errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }
            p.standardInput = stdinFile == nil ? FileHandle.nullDevice : inPipe

            p.terminationHandler = { proc in
                reader.wait()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                if stdoutFile == nil { out.append(outPipe.fileHandleForReading.readDataToEndOfFile()) }
                err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                if proc.terminationStatus == 0 {
                    cont.resume(returning: out.data)
                } else {
                    let msg = String(decoding: err.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(throwing: ShellError(message: msg.isEmpty ? "\((exe as NSString).lastPathComponent) exited with \(proc.terminationStatus)" : msg))
                }
            }
            if outFile != nil { reader.enter() }
            do { try p.run() } catch {
                if outFile != nil { try? outFile?.close(); reader.leave() }
                cont.resume(throwing: error); return
            }

            if let outFile {
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { try? outFile.close(); reader.leave() }
                    let r = outPipe.fileHandleForReading
                    var got: Int64 = 0
                    while case let chunk = r.availableData, !chunk.isEmpty {
                        do { try outFile.write(contentsOf: chunk) } catch {
                            err.append(Data("Couldn't save the download: \(error.localizedDescription)".utf8))
                            p.terminate()
                            return
                        }
                        got += Int64(chunk.count)
                        progress?(got)
                    }
                }
            }

            guard let src = stdinFile else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let w = inPipe.fileHandleForWriting
                defer { try? w.close() }
                guard let r = try? FileHandle(forReadingFrom: src) else { return }
                defer { try? r.close() }
                var sent: Int64 = 0
                while let chunk = try? r.read(upToCount: 1 << 20), !chunk.isEmpty {
                    do { try w.write(contentsOf: chunk) } catch { return }
                    sent += Int64(chunk.count)
                    progress?(sent)
                }
            }
        }
    }
}

/// Bytes moved so far in an upload or download, with a smoothed speed for the UI.
struct Transfer {
    var total: Int64?
    private(set) var done: Int64 = 0
    /// Average over the last few seconds, so the figure doesn't jitter with every chunk.
    private(set) var bytesPerSecond: Double = 0
    private var samples: [(at: Date, bytes: Int64)] = []

    init(total: Int64? = nil) { self.total = total }

    mutating func update(_ bytes: Int64, at now: Date = Date()) {
        done = bytes
        samples.append((now, bytes))
        samples.removeAll { now.timeIntervalSince($0.at) > 3 }
        if let first = samples.first, now.timeIntervalSince(first.at) >= 0.5 {
            bytesPerSecond = Double(bytes - first.bytes) / now.timeIntervalSince(first.at)
        }
    }

    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        return min(1, Double(done) / Double(total))
    }

    /// "45 MB of 120 MB · 12.3 MB/s · 8 s left"
    var text: String {
        var parts = [total.map { "\(Self.size(min(done, $0))) of \(Self.size($0))" } ?? Self.size(done)]
        if bytesPerSecond > 0 { parts.append(Self.size(Int64(bytesPerSecond)) + "/s") }
        if let total, bytesPerSecond > 0, done < total {
            let s = Double(total - done) / bytesPerSecond
            parts.append(s < 60 ? "\(max(1, Int(s.rounded()))) s left" : PCJob.timeLeft(s) ?? "")
        }
        return parts.joined(separator: " · ")
    }

    static func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

/// Passes byte counts from a transfer thread on at most a few times a second.
final class ByteMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date.distantPast
    private let report: @Sendable (Int64) -> Void
    init(_ report: @escaping @Sendable (Int64) -> Void) { self.report = report }

    func callAsFunction(_ bytes: Int64) {
        lock.lock()
        let now = Date(), due = now.timeIntervalSince(last) >= 0.25
        if due { last = now }
        lock.unlock()
        if due { report(bytes) }
    }
}
