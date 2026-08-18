// SpikeHarness — driver for the Spike-1 coexistence matrix
// (docs/spikes/spike1.md, SPEC §4.1/§7). This binary does NOT decide
// anything; it runs ONE matrix cell and emits a machine-readable verdict.
// `scripts/spike1-run.sh` orchestrates the full matrix.
//
// Output contract:
//   stdout — exactly ONE line: the verdict JSON (consumed by the runner).
//   stderr — human progress lines (every 30 s) + 10 s timeline JSONL.
//
// Exit codes:
//   0  verdict emitted (verdict.ok may still be false — that is data, not
//      a tooling failure)
//   10 microphone permission denied (after prompting)
//   11 screen recording permission denied (after requesting)
//   12 infra failure (tone generation / engine start threw)
//   64 usage error

import AVFAudio
import CaptureKit
import CoreGraphics
import Darwin
import Foundation

// MARK: - Output helpers

func errLog(_ line: String) {
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
}

func errJSON(_ json: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else { return }
    FileHandle.standardError.write(data)
    FileHandle.standardError.write("\n".data(using: .utf8)!)
}

// MARK: - Args

struct HarnessArgs {
    var order: RemoteStartOrder = .screenCaptureKitFirst
    var vp = true
    var duration: TimeInterval = 600
    var label = "run"
    var probe = false
    var tonePath = "/tmp/scribe-spike-tone.wav"

    var orderName: String { order == .screenCaptureKitFirst ? "sck-first" : "mic-first" }
}

func usage() {
    errLog("""
    USAGE: SpikeHarness [--probe] [--order sck|mic] [--vp on|off] \
    [--duration SEC] [--label NAME] [--tone-path PATH]
      --probe       permissions phase only (exit 0 granted / 10 mic / 11 screen)
      --order       sck = SCStream first (default) · mic = AVAudioEngine first
      --vp          on (default) / off — mic voice processing
      --duration    run length in seconds (default 600)
      --label       verdict label, e.g. "sck-first:vp-on@26.3"
      --tone-path   system-audio source WAV (default /tmp/scribe-spike-tone.wav)
    """)
}

func parseArgs(_ argv: [String]) -> HarnessArgs? {
    var args = HarnessArgs()
    var i = 1
    func next() -> String? {
        i += 1
        return i < argv.count ? argv[i] : nil
    }
    while i < argv.count {
        switch argv[i] {
        case "--order":
            guard let v = next() else { return nil }
            switch v {
            case "sck": args.order = .screenCaptureKitFirst
            case "mic": args.order = .audioEngineFirst
            default: return nil
            }
        case "--vp":
            guard let v = next() else { return nil }
            switch v {
            case "on": args.vp = true
            case "off": args.vp = false
            default: return nil
            }
        case "--duration":
            guard let v = next(), let d = Double(v), d > 0 else { return nil }
            args.duration = d
        case "--label":
            guard let v = next(), !v.isEmpty else { return nil }
            args.label = v
        case "--tone-path":
            guard let v = next(), !v.isEmpty else { return nil }
            args.tonePath = v
        case "--": // SwiftPM versions differ on whether they strip this
            break // separator before forwarding; accept either form.
        case "--probe":
            args.probe = true
        default:
            return nil
        }
        i += 1
    }
    return args
}

// MARK: - Permissions phase (TCC dance)

/// Preflight → request → re-preflight for both permissions. Returns the
/// process exit code (0 = both granted).
func permissionsPhase() async -> Int32 {
    errLog("== permissions phase ==")

    // Mic (SPEC §4.1): preflight, prompt, await, re-check.
    if AVAudioApplication.shared.recordPermission == .granted {
        errLog("mic: granted")
    } else {
        errLog("mic: not granted — requesting (answer the macOS prompt)…")
        _ = await AVAudioApplication.requestRecordPermission()
        if AVAudioApplication.shared.recordPermission != .granted {
            errLog("""
            MIC PERMISSION DENIED.
            Grant it, then rerun: System Settings → Privacy & Security → Microphone
            → enable for the app you launched this from (Terminal / iTerm / VS Code),
            quitting and reopening that app if it was already running.
            """)
            return 10
        }
        errLog("mic: granted")
    }

    // Screen recording (SPEC §4.1): CLI tools inherit the TCC identity of
    // their responsible (parent) app, so the grant lands on the terminal.
    if CGPreflightScreenCaptureAccess() {
        errLog("screen recording: granted")
    } else {
        errLog("screen recording: NOT granted — requesting (may open System Settings)…")
        _ = CGRequestScreenCaptureAccess()
        // Give TCC/System Settings a beat before re-preflighting.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        if !CGPreflightScreenCaptureAccess() {
            errLog("""
            SCREEN RECORDING PERMISSION NOT GRANTED.
            Grant it for the RESPONSIBLE app — the terminal/editor this harness was
            launched from (a CLI binary has no TCC identity of its own):
              System Settings → Privacy & Security → Screen Recording
              → enable that app → quit & reopen it → RERUN this harness.
            """)
            return 11
        }
        errLog("screen recording: granted")
    }
    return 0
}

// MARK: - Voice-processing probe

/// Best-effort probe of `setVoiceProcessingEnabled(true)` on a throwaway,
/// never-started engine, fully torn down BEFORE the real engine exists.
/// The real engine swallows VP-enable failure silently (SPEC §7 fallback
/// rung 2: fall back to VP off) and the seam does not surface it — this
/// probe is the only way the verdict can carry a `swiftRuntimeNote`.
/// Returns an error description when VP enable fails.
func voiceProcessingProbeError() -> String? {
    let probe = AVAudioEngine()
    defer { probe.stop() }
    do {
        try probe.inputNode.setVoiceProcessingEnabled(true)
        return nil
    } catch {
        return error.localizedDescription
    }
}

// MARK: - Timeline / progress reporting

func emitTimeline(_ elapsed: Int, _ stats: RunStats) {
    func chan(_ s: ChannelStats) -> [String: Any] {
        let snap = s.snapshot()
        return ["buffers": snap.buffers, "samples": snap.samples,
                "lastArrivalSec": snap.lastArrival.map { $0.rounded(to: 2) } ?? NSNull()]
            as [String: Any]
    }
    errJSON(["event": "timeline", "elapsedSec": elapsed,
             "mic": chan(stats.mic), "remote": chan(stats.remote)])
}

func emitProgress(_ elapsed: Int, _ stats: RunStats) {
    func line(_ name: String, _ s: ChannelStats) -> String {
        let snap = s.snapshot()
        if let first = snap.firstArrival {
            return "\(name): \(snap.buffers) buffers (first at \(first.rounded(to: 2)) s, max gap \(snap.maxGap.rounded(to: 2)) s)"
        }
        return "\(name): NO buffers delivered"
    }
    let degraded = stats.degradationLine().map { " · DEGRADED: \($0)" } ?? ""
    errLog("[\(elapsed) s] \(line("mic", stats.mic)) · \(line("remote", stats.remote))\(degraded)")
}

// MARK: - Verdict

/// Prints the single-line verdict JSON to stdout. `ok` = BOTH channels
/// delivered ≥ 50 buffers, first buffer arrived < 5 s, max inter-buffer
/// gap < 10 s, and no remote degradation fired.
@discardableResult
func emitVerdict(_ args: HarnessArgs, _ stats: RunStats,
                 notes: [String], swiftRuntimeNote: String?) -> Bool {
    func chanDict(_ s: ChannelStats) -> [String: Any] {
        let snap = s.snapshot()
        return ["buffers": snap.buffers,
                "samples": snap.samples,
                "firstArrivalMs": snap.firstArrival.map { Int(($0 * 1000).rounded()) } ?? NSNull(),
                "lastArrivalSec": snap.lastArrival.map { $0.rounded(to: 2) } ?? NSNull(),
                "maxGapSec": snap.maxGap.rounded(to: 2)] as [String: Any]
    }
    func channelOK(_ s: ChannelStats) -> Bool {
        let snap = s.snapshot()
        return snap.buffers >= 50
            && snap.firstArrival.map { $0 < 5.0 } ?? false
            && snap.maxGap < 10.0
    }
    let degraded = stats.degradationLine()
    let ok = channelOK(stats.mic) && channelOK(stats.remote) && degraded == nil

    var verdict: [String: Any] = [
        "label": args.label,
        "order": args.orderName,
        "vp": args.vp,
        "durationSec": Int(args.duration),
        "ok": ok,
        "mic": chanDict(stats.mic),
        "remote": chanDict(stats.remote),
        "remoteDegraded": degraded ?? NSNull(),
        "deviceChanges": stats.deviceChangeCount(),
        "notes": notes,
    ]
    if let note = swiftRuntimeNote {
        verdict["swiftRuntimeNote"] = note
    }

    guard let data = try? JSONSerialization.data(withJSONObject: verdict, options: [.sortedKeys]) else {
        errLog("FATAL: verdict JSON serialization failed")
        return false
    }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    return ok
}

// MARK: - Main

func runHarness(_ argv: [String]) async -> Int32 {
    guard let args = parseArgs(argv) else {
        usage()
        return 64
    }

    // Phase 1 — permissions (always first; --probe stops here).
    let permissionResult = await permissionsPhase()
    if permissionResult != 0 { return permissionResult }
    if args.probe {
        errLog("probe: both permissions granted — ready to run the matrix.")
        return 0
    }

    var notes: [String] = []
    var swiftRuntimeNote: String?

    // Phase 2 — system-audio source (child process; see ToneLoop doc).
    do {
        try ToneWriter.writeToneIfMissing(at: args.tonePath)
    } catch {
        errLog("FATAL: could not write tone WAV: \(error.localizedDescription)")
        return 12
    }

    // Phase 3 — VP probe (runs BEFORE the real engine exists; throwaway
    // engine, never started, torn down immediately).
    if args.vp {
        if let vpError = voiceProcessingProbeError() {
            swiftRuntimeNote = "VP enable failed (engine falls back to VP off): \(vpError)"
            notes.append(swiftRuntimeNote!)
        }
    }

    let stats = RunStats()
    let tone = ToneLoop(path: args.tonePath)
    tone.start()
    defer { tone.stop() }

    // Phase 4 — the run itself.
    errLog("== run: \(args.label) · order=\(args.orderName) · vp=\(args.vp ? "on" : "off") · \(Int(args.duration)) s ==")
    let engine = SCKCaptureEngine(config: .init(voiceProcessingEnabled: args.vp,
                                                startOrder: args.order))
    engine.onAudio = { stats.ingest($0) }
    engine.onRemoteDegraded = { stats.remoteDegraded($0) }
    engine.onDeviceChange = { stats.deviceChange() }

    do {
        try await engine.start()
    } catch {
        notes.append("engine.start() threw: \(error.localizedDescription)")
        emitVerdict(args, stats, notes: notes, swiftRuntimeNote: swiftRuntimeNote)
        return 12
    }

    // Ctrl-C ends the run early (clean stop + partial verdict) instead of
    // killing the process mid-stream.
    signal(SIGINT, SIG_IGN)
    let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigint.setEventHandler { stats.requestStop() }
    sigint.resume()
    defer { sigint.cancel() }

    var lastTimeline = 0
    var lastProgress = 0
    while !stats.isStopRequested() {
        if stats.elapsedSec() >= args.duration { break }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        let elapsed = Int(stats.elapsedSec())
        if elapsed >= lastTimeline + 10 {
            lastTimeline = elapsed - elapsed % 10
            emitTimeline(elapsed, stats)
        }
        if elapsed >= lastProgress + 30 {
            lastProgress = elapsed - elapsed % 30
            emitProgress(elapsed, stats)
        }
    }
    if stats.isStopRequested() {
        notes.append("interrupted (SIGINT) at \(Int(stats.elapsedSec())) s — verdict covers a partial run")
    }

    // Phase 5 — teardown + verdict.
    await engine.stop()
    tone.stop()
    if tone.restarts > 0 { notes.append("afplay tone restarted \(tone.restarts)× (30 s file loops)") }
    if tone.launchErrors > 0 { notes.append("afplay launch errors: \(tone.launchErrors)") }

    let ok = emitVerdict(args, stats, notes: notes, swiftRuntimeNote: swiftRuntimeNote)
    errLog("== verdict: \(ok ? "OK" : "FAILED") — full JSON on stdout ==")
    return 0
}

// Top-level entry (async allowed in main.swift).
let exitCode = await runHarness(CommandLine.arguments)
if exitCode != 0 { exit(exitCode) }
