// Player.swift
// nanoMIDI - All-in-One (with MIDI import + whitespace fix)

import Foundation
import CoreGraphics
import Accessibility
import AppKit


// MARK: - Player
final class NanoMIDIAutomation {
    enum State: Equatable { case idle, playing, paused, finished }
    enum Event { case press(Character, units: Int), chord([Character], units: Int), rest(Int) }

    // Public API
    private(set) var state: State = .idle { didSet { onStateChange?(state) } }
    var tempoBPM: Double = 120 { didSet { recalcUnitDuration() } }
    var noteUnitDenominator: Int = 16 { didSet { recalcUnitDuration() } }
    private(set) var unitDuration: TimeInterval = 0.10
    var holdFraction: Double = 0.90

    // rests
    var restWeightSpace = 1
    var restWeightPipe  = 3

    /// false: ลบ whitespace ทั้งหมดก่อนพาร์ส (แนะนำ; ตรงปัญหาเวลาเกิน)
    /// true : ช่องว่าง = พัก (legacy)
    var treatSpaceAsRest: Bool = false

    var onStateChange: ((State) -> Void)?
    var onStep: ((Event) -> Void)?

    init(script: String = "") { recalcUnitDuration(); load(script); ensureAccessibilityNote() }

    // MARK: - Load & Meta
    /// Load a nanoMIDI script into the automation engine.
    /// Newline characters are stripped out before parsing so that line breaks do not
    /// generate unintended rest events. If `treatSpaceAsRest` is true, spaces will
    /// be converted into rest units during parsing; otherwise all whitespace
    /// characters (space, tab) will be removed entirely.
    func load(_ script: String) {
        // Apply meta directives first (handles @bpm, @unit, @hold, @fit, @spaceRest)
        let rawNotes = applyMetaDirectives(script)

        // Remove all newline characters. Newlines in the script should not be
        // interpreted as rests or notes. This prevents unexpected pauses when
        // scripts contain line breaks.
        let noNewlines = rawNotes.replacingOccurrences(of: "\n", with: "")

        // Depending on treatSpaceAsRest, either keep spaces (so they become rests)
        // or strip out all whitespace entirely. Note that we already removed
        // newline characters above.
        let noteOnly: String
        if treatSpaceAsRest {
            noteOnly = noNewlines
        } else {
            // Filter out all remaining whitespace characters (spaces, tabs) when
            // spaces should not be treated as rests.
            noteOnly = noNewlines.unicodeScalars
                .filter { !$0.properties.isWhitespace }
                .reduce(into: "") { $0.append(String($1)) }
        }

        // Parse the processed script into events and reset playback state
        events = parse(noteOnly)
        cursor = 0
        state = .idle
    }

    private func recalcUnitDuration() {
        let quarter = 60.0 / max(tempoBPM, 1e-6)
        unitDuration = quarter * (4.0 / Double(max(noteUnitDenominator, 1)))
    }

    /// Meta:
    /// @bpm <Double> | @unit <Int> | @hold <0..1>
    /// @fit <...s|sec|seconds or ...m|min|minute|minutes>
    /// @spaceRest on|off|true|false|1|0
    private func applyMetaDirectives(_ input: String) -> String {
        var bpm: Double?; var unit: Int?; var hold: Double?
        var fitSeconds: Double?; var spaceRest: Bool?
        var noteLines: [String] = []

        for raw in input.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("@") else { noteLines.append(String(raw)); continue }
            let parts = line.dropFirst().split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let key = parts.first?.lowercased() ?? ""; let val = parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespaces) : ""

            switch key {
            case "bpm":  if let v = Double(val) { bpm = v }
            case "unit": if let v = Int(val) { unit = v }
            case "hold": if let v = Double(val) { hold = min(max(v, 0.0), 1.0) }
            case "fit":
                let lower = val.lowercased()
                if lower.contains("m") || lower.contains("min") {
                    let num = lower.replacingOccurrences(of: "minutes", with: "")
                        .replacingOccurrences(of: "minute", with: "")
                        .replacingOccurrences(of: "mins", with: "")
                        .replacingOccurrences(of: "min", with: "")
                        .replacingOccurrences(of: "m", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let n = Double(num) { fitSeconds = n * 60.0 }
                } else {
                    let num = lower.replacingOccurrences(of: "seconds", with: "")
                        .replacingOccurrences(of: "second", with: "")
                        .replacingOccurrences(of: "secs", with: "")
                        .replacingOccurrences(of: "sec", with: "")
                        .replacingOccurrences(of: "s", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if let n = Double(num) { fitSeconds = n }
                }
            case "spacerest":
                let v = val.lowercased(); spaceRest = (v == "on" || v == "1" || v == "true")
            default: break
            }
        }

        if let b = bpm { self.tempoBPM = b }
        if let u = unit, u > 0 { self.noteUnitDenominator = u }
        if let h = hold { self.holdFraction = h }
        if let sr = spaceRest { self.treatSpaceAsRest = sr }
        recalcUnitDuration()

        if let fit = fitSeconds, fit > 0 {
            let pre: String = {
                if self.treatSpaceAsRest { return noteLines.joined(separator: "\n") }
                let joined = noteLines.joined(separator: "\n")
                return joined.unicodeScalars.filter{ !$0.properties.isWhitespace }.reduce(into: "") { $0.append(String($1)) }
            }()
            let tmp = parse(pre)
            let s = durationStats(of: tmp)
            let totalUnits = Double(s.pressUnits + s.chordUnits + s.restUnits)
            if totalUnits > 0 {
                let denom = Double(max(self.noteUnitDenominator, 1))
                let newBPM = 60.0 * (4.0 / denom) * (totalUnits / fit)
                self.tempoBPM = max(10, min(newBPM, 480))
                recalcUnitDuration()
            }
        }

        return noteLines.joined(separator: "\n")
    }

    // MARK: - Parser
    private func parse(_ input: String) -> [Event] {
        var out: [Event] = []; var i = input.startIndex
        func readTies(_ s: String, _ idx: inout String.Index) -> Int {
            var t = 0; var j = idx
            while j < s.endIndex, s[j] == "-" { t += 1; j = s.index(after: j) }
            idx = j; return t
        }

        while i < input.endIndex {
            let c = input[i]

            // chord [ ... ]
            if c == "[" {
                var arr: [Character] = []; i = input.index(after: i)
                while i < input.endIndex, input[i] != "]" {
                    let ch = input[i]; if ch != "]" && !ch.isWhitespace { arr.append(ch) }
                    i = input.index(after: i)
                }
                if i < input.endIndex, input[i] == "]" { i = input.index(after: i) }
                let ties = (i < input.endIndex && input[i] == "-") ? readTies(input, &i) : 0
                if !arr.isEmpty { out.append(.chord(arr, units: max(1, 1 + ties))) }
                continue
            }

            // long rest with |
            if c == "|" {
                var count = 0
                while i < input.endIndex, input[i] == "|" {
                    count += 1
                    i = input.index(after: i)
                }
                out.append(.rest(max(1, count * restWeightPipe)))
                continue
            }

            // single note / token
            if c.isLetter || c.isNumber || c.isPunctuation {
                let ch = c; i = input.index(after: i)
                let ties = (i < input.endIndex && input[i] == "-") ? readTies(input, &i) : 0
                out.append(.press(ch, units: max(1, 1 + ties)))
                continue
            }

            i = input.index(after: i) // skip other
        }

        // merge rests
        var merged: [Event] = []; var buf = 0
        for e in out {
            switch e {
            case .rest(let n): buf += n
            default:
                if buf > 0 { merged.append(.rest(buf)); buf = 0 }
                merged.append(e)
            }
        }
        if buf > 0 { merged.append(.rest(buf)) }
        return merged
    }

    // MARK: - Playback
    func start() { guard state != .playing, !events.isEmpty else { return }; cancelCurrentTask(); state = .playing; playTask = Task { await run() } }
    func pause() { guard state == .playing else { return }; state = .paused }
    func resume() { guard state == .paused else { return }; state = .playing; playTask = Task { await run() } }
    func stop() { cancelCurrentTask(); cursor = 0; state = .idle }

    private func runPress(_ ch: Character, units: Int) async {
        let total = unitDuration * Double(max(units, 1)), downFor = total * holdFraction
        runKeyDown(ch); try? await Task.sleep(nanoseconds: UInt64(downFor * 1_000_000_000)); runKeyUp(ch)
        let gap = max(0, total - downFor); if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
    }
    private func runChord(_ arr: [Character], units: Int) async {
        let total = unitDuration * Double(max(units, 1)), downFor = total * holdFraction
        for ch in arr { runKeyDown(ch) }; try? await Task.sleep(nanoseconds: UInt64(downFor * 1_000_000_000)); for ch in arr { runKeyUp(ch) }
        let gap = max(0, total - downFor); if gap > 0 { try? await Task.sleep(nanoseconds: UInt64(gap * 1_000_000_000)) }
    }
    private func runRest(_ units: Int) async { let t = unitDuration * Double(max(units, 1)); try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000)) }

    private func advanceCursor() { cursor += 1 }
    private func currentEvent() -> Event? { (cursor >= 0 && cursor < events.count) ? events[cursor] : nil }

    private func ensureAccessibilityNote() {
        if !AXIsProcessTrusted() {
            print("Enable Accessibility for keyboard automation: System Settings → Privacy & Security → Accessibility.")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
        }
    }

    private func run() async {
        ensureAccessibilityNote()
        while !Task.isCancelled {
            if state != .playing { break }
            guard let e = currentEvent() else { break }
            onStep?(e)
            switch e {
            case .press(let ch, let u):  await runPress(ch, units: u)
            case .chord(let arr, let u): await runChord(arr, units: u)
            case .rest(let n):           await runRest(n)
            }
            advanceCursor()
            if cursor >= events.count { state = .finished; break }
        }
    }

    // MARK: - Key mapping for CGEvents
    private static func keyCode(for ch: Character) -> CGKeyCode? {
        switch ch {
        case "a": return CGKeyCode(Keycode.a); case "b": return CGKeyCode(Keycode.b); case "c": return CGKeyCode(Keycode.c)
        case "d": return CGKeyCode(Keycode.d); case "e": return CGKeyCode(Keycode.e); case "f": return CGKeyCode(Keycode.f)
        case "g": return CGKeyCode(Keycode.g); case "h": return CGKeyCode(Keycode.h); case "i": return CGKeyCode(Keycode.i)
        case "j": return CGKeyCode(Keycode.j); case "k": return CGKeyCode(Keycode.k); case "l": return CGKeyCode(Keycode.l)
        case "m": return CGKeyCode(Keycode.m); case "n": return CGKeyCode(Keycode.n); case "o": return CGKeyCode(Keycode.o)
        case "p": return CGKeyCode(Keycode.p); case "q": return CGKeyCode(Keycode.q); case "r": return CGKeyCode(Keycode.r)
        case "s": return CGKeyCode(Keycode.s); case "t": return CGKeyCode(Keycode.t); case "u": return CGKeyCode(Keycode.u)
        case "v": return CGKeyCode(Keycode.v); case "w": return CGKeyCode(Keycode.w); case "x": return CGKeyCode(Keycode.x)
        case "y": return CGKeyCode(Keycode.y); case "z": return CGKeyCode(Keycode.z)
        case "0": return CGKeyCode(Keycode.zero); case "1": return CGKeyCode(Keycode.one); case "2": return CGKeyCode(Keycode.two)
        case "3": return CGKeyCode(Keycode.three); case "4": return CGKeyCode(Keycode.four); case "5": return CGKeyCode(Keycode.five)
        case "6": return CGKeyCode(Keycode.six); case "7": return CGKeyCode(Keycode.seven); case "8": return CGKeyCode(Keycode.eight)
        case "9": return CGKeyCode(Keycode.nine)
        case " ": return CGKeyCode(Keycode.space); case "-": return CGKeyCode(Keycode.minus); case "=": return CGKeyCode(Keycode.equals)
        case "[": return CGKeyCode(Keycode.leftBracket); case "]": return CGKeyCode(Keycode.rightBracket)
        case ";": return CGKeyCode(Keycode.semicolon); case "'": return CGKeyCode(Keycode.apostrophe)
        case ",": return CGKeyCode(Keycode.comma); case ".": return CGKeyCode(Keycode.period); case "/": return CGKeyCode(Keycode.forwardSlash)
        case "\\": return CGKeyCode(Keycode.backslash); case "`": return CGKeyCode(Keycode.grave)
        default:
            if let lower = String(ch).lowercased().first, lower != ch { return keyCode(for: lower) }
            return nil
        }
    }
    private func runKeyDown(_ ch: Character) {
        guard let lower = String(ch).lowercased().first, let vk = Self.keyCode(for: lower) else { return }
        if ch.isUppercase { sendKey(Keycode.shift, down: true) }
        sendKey(UInt16(vk), down: true)
    }
    private func runKeyUp(_ ch: Character) {
        guard let lower = String(ch).lowercased().first, let vk = Self.keyCode(for: lower) else { return }
        sendKey(UInt16(vk), down: false)
        if ch.isUppercase { sendKey(Keycode.shift, down: false) }
    }
    private func sendKey(_ vk: UInt16, down: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(vk), keyDown: down)?.post(tap: .cghidEventTap)
    }

    // MARK: - Duration helpers
    private func durationStats(of list: [Event]) -> (pressUnits: Int, chordUnits: Int, restUnits: Int) {
        var p = 0, c = 0, r = 0
        for e in list {
            switch e {
            case .press(_, let u): p += max(1, u)
            case .chord(_, let u): c += max(1, u)
            case .rest(let n):     r += max(0, n)
            }
        }
        return (p, c, r)
    }
    func expectedDurationSeconds() -> Double {
        let s = durationStats(of: events)
        let totalUnits = Double(s.pressUnits + s.chordUnits + s.restUnits)
        return totalUnits * unitDuration
    }
    @discardableResult
    func fitTotalDuration(to totalSeconds: TimeInterval) -> Bool {
        guard totalSeconds > 0 else { return false }
        let s = durationStats(of: events); let totalUnits = Double(s.pressUnits + s.chordUnits + s.restUnits)
        guard totalUnits > 0 else { return false }
        let denom = Double(max(noteUnitDenominator, 1))
        let newBPM = 60.0 * (4.0 / denom) * (totalUnits / totalSeconds)
        tempoBPM = max(10, min(newBPM, 480)); recalcUnitDuration(); return true
    }

    // MARK: - MIDI Import (fixed permission)
    func loadMIDIFileData(_ data: Data, keyMapping: [UInt8: Character]? = nil) throws -> String {
        let reader = MIDIReader(data: data)
        let midi = try reader.parseMIDIFile()
        let script = reader.convertToNanoMIDIScript(midi, keyMapping: keyMapping)
        self.load(script)
        return script
    }

    /// โหลดจาก URL (รองรับ security-scoped URL + iCloud)
    @discardableResult
    func loadMIDIFile(from url: URL, keyMapping: [UInt8: Character]? = nil) throws -> String {
        // ขอสิทธิ์ security-scoped ถ้ามี
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // ถ้าเป็น iCloud ให้ดาวน์โหลดลงเครื่องก่อน และตรวจสิทธิ์อ่าน
        try ensureLocalFile(at: url)

        // อ่านข้อมูล
        let data = try Data(contentsOf: url, options: .mappedIfSafe)

        // แปลงและโหลดเข้า player
        return try loadMIDIFileData(data, keyMapping: keyMapping)
    }

    /// ดาวน์โหลดไฟล์ iCloud ถ้ายังไม่ได้อยู่ local + ตรวจสิทธิ์อ่าน
    private func ensureLocalFile(at url: URL) throws {
        var values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
            .isReadableKey,
            .isRegularFileKey
        ])

        if values.isUbiquitousItem == true {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                values = try url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if values.ubiquitousItemDownloadingStatus == URLUbiquitousItemDownloadingStatus.current {
                    break
                }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }

        values = try url.resourceValues(forKeys: [.isReadableKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.isReadable == true else {
            throw NSError(domain: NSCocoaErrorDomain,
                          code: NSFileReadNoPermissionError,
                          userInfo: [NSLocalizedDescriptionKey:
                                     "No read permission for file at \(url.path)"])
        }
    }

    // Internals
    private var events: [Event] = []; private var cursor: Int = 0; private var playTask: Task<Void, Never>?
    private func cancelCurrentTask() { playTask?.cancel(); playTask = nil }
}
