//
//  Metadata_WashApp.swift
//  Metadata Wash
//
//  Created by Gus on 2026-10-10.
//

import SwiftUI

@main
struct Metadata_WashApp: App {
    @State private var queue = CleaningQueue()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(queue)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Clean All") { queue.cleanAll() }
                    .disabled(queue.cleanableItems.isEmpty || queue.isCleaning)
                Button("Show Cleaned Files in Finder") { queue.revealAllOutputs() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(!queue.items.contains { $0.result?.outputURL != nil })
            }
            CommandGroup(replacing: .help) {
                OpenAcknowledgementsButton()
            }
        }

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .windowResizability(.contentSize)
    }
}

private struct OpenAcknowledgementsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Third-Party Notices") { openWindow(id: "acknowledgements") }
    }
}
