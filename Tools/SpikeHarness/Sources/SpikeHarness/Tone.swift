import Foundation

// MARK: - System-audio source (child afplay loop)
//
// The engine configures SCStream with `excludesCurrentProcessAudio = true`
// (SPEC §4.1), so audio played by the harness process itself would be
// excluded from the remote channel — the tone MUST come from a SEPARATE
// process. `afplay` is that process; this class keeps it looping for the
// whole run and kills it at the end.

final class ToneLoop: @unchecked Sendable {

    private let path: String
    private let queue = DispatchQueue(label: "spike.tone.loop")
    private let lock = NSLock()
    private var current: Process?
    private var running = false
    private(set) var restarts = 0
    private(set) var launchErrors = 0

    init(path: String) {
        self.path = path
    }

    /// Starts the loop asynchronously on a private queue (blocks that queue
    /// for the whole run — `waitUntilExit` parks there, by design).
    func start() {
        lock.lock()
        running = true
        lock.unlock()
        queue.async { [weak self] in self?.loop() }
    }

    private func loop() {
        while true {
            lock.lock()
            guard running else { lock.unlock(); return }
            lock.unlock()

            let player = Process()
            player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
            player.arguments = [path]
            // Keep afplay silent so the harness's stderr/stdout stay clean.
            player.standardOutput = FileHandle.nullDevice
            player.standardError = FileHandle.nullDevice
            do {
                try player.run()
            } catch {
                lock.lock()
                launchErrors += 1
                let fatal = !running // already stopped → normal exit path
                lock.unlock()
                if fatal { return }
                errLog("tone: afplay failed to launch (\(error.localizedDescription)); retrying in 5 s")
                Thread.sleep(forTimeInterval: 5)
                continue
            }
            lock.lock()
            current = player
            lock.unlock()

            player.waitUntilExit() // 30 s of tone, then exit → restart

            lock.lock()
            current = nil
            let stillRunning = running
            restarts += 1
            lock.unlock()
            if !stillRunning { return }
        }
    }

    /// Idempotent: stops the loop and SIGTERMs any in-flight afplay.
    func stop() {
        lock.lock()
        running = false
        let player = current
        current = nil
        lock.unlock()
        if let player, player.isRunning {
            player.terminate()
        }
    }
}

// MARK: - Tone WAV generation (hand-rolled RIFF, no AVFoundation writer)

enum ToneWriter {

    /// Writes the 30 s looping tone if the file is missing: 440 Hz sine,
    /// amplitude-modulated at 0.5 Hz so the remote channel carries dynamics
    /// (a steady tone can hide buffer dropouts less visibly), at a LOW peak
    /// (−22 dBFS) — audible to SCStream, not annoying to a human.
    static func writeToneIfMissing(at path: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: path) else { return }

        let sampleRate = 44_100
        let seconds = 30.0
        let frames = Int(Double(sampleRate) * seconds)
        let dataBytes = frames * 2 // 16-bit mono

        var data = Data(capacity: 44 + dataBytes)
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }

        // RIFF header + fmt (PCM) + data chunks, all little-endian.
        ascii("RIFF"); le32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); le32(16); le16(1) // PCM
        le16(1)                            // mono
        le32(UInt32(sampleRate))
        le32(UInt32(sampleRate * 2))       // byte rate = rate × channels × 2
        le16(2)                            // block align
        le16(16)                           // bits per sample
        ascii("data"); le32(UInt32(dataBytes))

        let peak = 0.08
        for n in 0..<frames {
            let t = Double(n) / Double(sampleRate)
            let envelope = 0.5 + 0.5 * sin(2 * .pi * 0.5 * t) // 0.5 Hz AM
            let value = peak * envelope * sin(2 * .pi * 440 * t)
            let clamped = max(-1.0, min(1.0, value))
            le16(UInt16(bitPattern: Int16(clamped * 32767.0)))
        }

        try data.write(to: URL(fileURLWithPath: path))
        errLog("tone: wrote \(Int(seconds)) s tone to \(path)")
    }
}
