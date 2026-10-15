import Foundation

/// A `caffeinate` child that holds off idle and system sleep, so keep-warm
/// pings keep firing while the Mac sits unattended. `-w` ties it to this
/// process, so it dies with the app even after a crash.
final class Caffeinate {
    private var process: Process?
    var onExit: (() -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }

    func start() throws {
        guard !isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        p.arguments = ["-i", "-s", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.process === p else { return }
                self.process = nil
                self.onExit?()
            }
        }
        try p.run()
        process = p
    }

    func stop() {
        process?.terminate()
        process = nil
    }
}

/// Whether `pmset disablesleep` is on. Unlike caffeinate, it also keeps the Mac
/// awake with the lid closed, and it outlives the app until turned off.
func sleepDisabled() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .contains { $0.split(whereSeparator: \.isWhitespace) == ["SleepDisabled", "1"] }
}

/// Sets `pmset -a disablesleep`. It needs root, so macOS asks for an admin
/// password. Blocks until the prompt is answered; call off main.
func setSleepDisabled(_ on: Bool) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"]
    let err = Pipe()
    p.standardError = err
    p.standardOutput = FileHandle.nullDevice
    do { try p.run() } catch { return error.localizedDescription }
    let data = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus != 0 else { return nil }
    let msg = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    return msg.contains("-128") ? "" : (msg.isEmpty ? "pmset failed" : msg)
}
