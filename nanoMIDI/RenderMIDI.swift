//
//  RenderMIDI.swift
//  nanoMIDI
//
//  Created by KrataiB on 24/8/2568 BE.
//
import AppKit


// MARK: - MIDI Structures
struct MIDIFile { let format: UInt16; let trackCount: UInt16; let timeDivision: UInt16; let tracks: [MIDITrack] }
struct MIDITrack { let events: [MIDIEvent] }
struct MIDIEvent { let deltaTime: UInt32; let event: MIDIEventType }

enum MIDIEventType {
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8, velocity: UInt8)
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case programChange(channel: UInt8, program: UInt8)
    case meta(type: UInt8, data: Data)
    case sysex(data: Data)
    case unknown
}

// MARK: - MIDI Reader
final class MIDIReader {
    private var data: Data; private var position: Int = 0
    init(data: Data) { self.data = data }

    func parseMIDIFile() throws -> MIDIFile {
        position = 0
        guard readString(4) == "MThd" else { throw MIDIError.invalidFormat("Not a MIDI file") }
        let headerLength = readUInt32(); guard headerLength == 6 else { throw MIDIError.invalidFormat("Bad header length") }
        let format = readUInt16(); let trackCount = readUInt16(); let timeDivision = readUInt16()
        var tracks: [MIDITrack] = []; tracks.reserveCapacity(Int(trackCount))
        for _ in 0..<trackCount { tracks.append(try readTrack()) }
        return MIDIFile(format: format, trackCount: trackCount, timeDivision: timeDivision, tracks: tracks)
    }

    private func readTrack() throws -> MIDITrack {
        guard readString(4) == "MTrk" else { throw MIDIError.invalidFormat("Invalid track header") }
        let trackLength = readUInt32(); let end = position + Int(trackLength)
        var events: [MIDIEvent] = []; var running: UInt8 = 0
        while position < end {
            let dt = readVariableLength()
            let ev = try readEvent(&running)
            events.append(MIDIEvent(deltaTime: dt, event: ev))
        }
        return MIDITrack(events: events)
    }

    private func readEvent(_ running: inout UInt8) throws -> MIDIEventType {
        let statusByte = peekUInt8()
        if statusByte >= 0x80 { running = readUInt8() }
        let status = running, channel = status & 0x0F, type = status & 0xF0
        switch type {
        case 0x80:
            let note = readUInt8(), vel = readUInt8(); return .noteOff(channel: channel, note: note, velocity: vel)
        case 0x90:
            let note = readUInt8(), vel = readUInt8(); return vel == 0 ? .noteOff(channel: channel, note: note, velocity: vel) : .noteOn(channel: channel, note: note, velocity: vel)
        case 0xB0:
            let cc = readUInt8(), val = readUInt8(); return .controlChange(channel: channel, controller: cc, value: val)
        case 0xC0:
            let prog = readUInt8(); return .programChange(channel: channel, program: prog)
        case 0xF0:
            if status == 0xFF {
                let metaType = readUInt8(); let len = readVariableLength(); let metaData = readData(Int(len))
                return .meta(type: metaType, data: metaData)
            } else if status == 0xF0 {
                let len = readVariableLength(); let syx = readData(Int(len)); return .sysex(data: syx)
            }
        default: break
        }
        return .unknown
    }

    // MARK: - Data helpers
    private func readUInt8() -> UInt8 { guard position < data.count else { return 0 }; defer { position += 1 }; return data[position] }
    private func peekUInt8() -> UInt8 { guard position < data.count else { return 0 }; return data[position] }
    private func readUInt16() -> UInt16 { let hi = UInt16(readUInt8()), lo = UInt16(readUInt8()); return (hi << 8) | lo }
    private func readUInt32() -> UInt32 {
        let b1 = UInt32(readUInt8()), b2 = UInt32(readUInt8()), b3 = UInt32(readUInt8()), b4 = UInt32(readUInt8())
        return (b1 << 24) | (b2 << 16) | (b3 << 8) | b4
    }
    private func readVariableLength() -> UInt32 {
        var val: UInt32 = 0, byte: UInt8
        repeat { byte = readUInt8(); val = (val << 7) | UInt32(byte & 0x7F) } while (byte & 0x80) != 0
        return val
    }
    private func readString(_ n: Int) -> String { String(data: readData(n), encoding: .ascii) ?? "" }
    private func readData(_ n: Int) -> Data { let end = min(position + n, data.count); defer { position = end }; return data.subdata(in: position..<end) }

    // MARK: - Convert MIDI -> nanoMIDI script
    func convertToNanoMIDIScript(_ midi: MIDIFile, keyMapping: [UInt8: Character]? = nil) -> String {
        let mapping = keyMapping ?? createDefaultKeyMapping()
        var script = "@unit 16\n"
        guard let track = midi.tracks.first else { return script }

        var t: UInt32 = 0
        var events: [(time: UInt32, token: String)] = []

        for e in track.events {
            t &+= e.deltaTime
            switch e.event {
            case .noteOn(_, let note, let vel):
                if vel > 0, let ch = mapping[note] { events.append((t, String(ch))) }
            case .meta(let type, let data):
                if type == 0x51, data.count == 3 {
                    let usPerQ = (UInt32(data[0]) << 16) | (UInt32(data[1]) << 8) | UInt32(data[2])
                    let bpm = (60_000_000.0 / Double(usPerQ)).rounded()
                    script += "@bpm \(Int(bpm))\n"
                }
            default: break
            }
        }

        events.sort { $0.time < $1.time }
        let tpq = Int(midi.timeDivision)
        let unit = max(1, tpq / 4) // 16th

        var last: UInt32 = 0
        for e in events {
            let diff = Int(e.time &- last)
            let restUnits = diff / unit
            if restUnits > 0 {
                script += String(repeating: "|", count: min(restUnits, 16))
            }
            script += e.token
            last = e.time
        }
        return script
    }

    private func createDefaultKeyMapping() -> [UInt8: Character] {
        var map: [UInt8: Character] = [:]
        let white: [Character] = ["a","s","d","f","g","h","j","k","l"]
        let whiteNotes: [UInt8] = [60,62,64,65,67,69,71,72,74]
        for (i,n) in whiteNotes.enumerated() where i < white.count { map[n] = white[i] }
        let black: [Character] = ["w","e","t","y","u","o","p"]
        let blackNotes: [UInt8] = [61,63,66,68,70,73,75]
        for (i,n) in blackNotes.enumerated() where i < black.count { map[n] = black[i] }
        return map
    }
}

// MARK: - Errors
enum MIDIError: Error, LocalizedError {
    case invalidFormat(String), unsupportedFeature(String)
    var errorDescription: String? {
        switch self {
        case .invalidFormat(let m): return "Invalid MIDI format: \(m)"
        case .unsupportedFeature(let m): return "Unsupported MIDI feature: \(m)"
        }
    }
}
