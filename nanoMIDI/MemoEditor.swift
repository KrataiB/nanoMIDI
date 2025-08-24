//
//  MemoEditor.swift
//  nanoMIDI
//
//  Created by KrataiB on 23/8/2568 BE.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct MemoEditor: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var memo: Memo

    @State private var showSaved = false
    @State private var saveWorkItem: DispatchWorkItem?

    // Player
    @State private var player = NanoMIDIAutomation()
    @State private var playerState: NanoMIDIAutomation.State = .idle
    
    // MIDI import states
    @State private var showingMIDIImporter = false
    @State private var lastImportedMIDI: String = ""

    var body: some View {
        VStack(spacing: 12) {
            // Editor
            TextEditor(text: $memo.text)
                .padding(8)
                .frame(minHeight: 180)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onChange(of: memo.text) { _, newValue in
                    memo.updatedAt = .now

                    // โหลดสคริปต์เข้าตัว player ทุกครั้งที่แก้ไข
                    player.load(newValue)

                    // ขึ้นบรรทัดใหม่ → save ทันที
                    if newValue.hasSuffix("\n") {
                        quickSave(showToast: true)
                        return
                    }

                    // เดบาวน์ 0.6 วินาที
                    saveWorkItem?.cancel()
                    let work = DispatchWorkItem { [weak modelContext] in
                        guard let _ = modelContext else { return }
                        quickSave(showToast: false)
                    }
                    saveWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }

            // Controls
            HStack(spacing: 8) {
                Button {
                    showingMIDIImporter = true
                } label: {
                    Label("Import MIDI", systemImage: "music.note")
                }
                .buttonStyle(.bordered)
                
                Spacer()
                
                Button {
                    player.start()
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("'", modifiers: [.command])

                Button {
                    (playerState == .paused) ? player.resume() : player.pause()
                } label: {
                    Label(playerState == .paused ? "Resume" : "Pause",
                          systemImage: playerState == .paused ? "playpause.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.space)

                Button {
                    player.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(".", modifiers: [.command])

                Button {
                    quickSave(showToast: true)
                } label: {
                    Label("Save", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: [.command])
            }

            // Player status
            HStack {
                Circle().fill(color(for: playerState)).frame(width: 8, height: 8)
                Text(statusText(for: playerState))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .toast("Saved!", isPresented: $showSaved)
        .fileImporter(
            isPresented: $showingMIDIImporter,
            allowedContentTypes: [UTType(filenameExtension: "mid")!, UTType(filenameExtension: "midi")!],
            allowsMultipleSelection: false
        ) { result in
            handleMIDIImport(result)
        }
        .onAppear {
            // โหลดสคริปต์จากโน้ตปัจจุบัน และฟัง state
            player.load(memo.text)

            // ปรับให้ responsive ขึ้น และไม่เผลอนับช่องว่างเป็นพัก
            player.holdFraction = 0.55
            player.treatSpaceAsRest = false

            print("Expected:", player.expectedDurationSeconds())
            player.onStateChange = { newState in
                playerState = newState
            }
        }
        .onDisappear {
            // Save + Stop
            saveWorkItem?.cancel()
            try? modelContext.save()
            player.stop()
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - MIDI Import Handler
    private func handleMIDIImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                // ใช้ default mapping ภายใน Player/Reader
                let script = try player.loadMIDIFile(from: url, keyMapping: nil)
                memo.text = script
                lastImportedMIDI = script
                withAnimation { showSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    withAnimation { showSaved = false }
                }
            } catch {
                print("Failed to import MIDI: \(error.localizedDescription)")
            }
        case .failure(let error):
            print("File import failed: \(error.localizedDescription)")
        }
    }
    
    private func getLastGeneratedScript() -> String? {
        lastImportedMIDI.isEmpty ? nil : lastImportedMIDI
    }

    // MARK: - Save Helper
    private func quickSave(showToast: Bool) {
        do {
            try modelContext.save()
            if showToast {
                withAnimation { showSaved = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    withAnimation { showSaved = false }
                }
            }
        } catch {
            #if DEBUG
            print("Save failed:", error.localizedDescription)
            #endif
        }
    }

    // MARK: - UI helpers
    private func color(for state: NanoMIDIAutomation.State) -> Color {
        switch state {
        case .idle: return .gray
        case .playing: return .green
        case .paused: return .yellow
        case .finished: return .blue
        }
    }

    private func statusText(for state: NanoMIDIAutomation.State) -> String {
        switch state {
        case .idle: return "Idle"
        case .playing: return "Playing (automation)"
        case .paused: return "Paused"
        case .finished: return "Finished"
        }
    }
}
