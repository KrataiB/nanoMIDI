//
//  nanoMIDIApp.swift
//  nanoMIDI
//
//  Created by KrataiB on 23/8/2568 BE.
//

import SwiftUI
import SwiftData

@main
struct nanoMIDIApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Memo.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
