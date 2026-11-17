// The native iOS client of the private shielded sync proof of concept: the web step page's steps, with the scan and
// the PIR multiplications on the GPU through Metal and the Midnight crypto from the ledger's Rust crates.

import SwiftUI

@main
struct PssApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .background(Color(uiColor: .systemGroupedBackground))
                .task {
                    // PSS_AUTORUN=device,keys,files,scan,read,nullifiers,paths,tail,summary or wallet (Simulator runs).
                    if let list = ProcessInfo.processInfo.environment["PSS_AUTORUN"] {
                        model.backgroundTest = ProcessInfo.processInfo.environment["PSS_BACKGROUND_TEST"] == "1"
                        model.autorun(list.split(separator: ",").map(String.init))
                    } else {
                        model.openSavedWallet()
                    }
                }
        }
        .onChange(of: phase) { _, p in
            if p == .background { model.enteredBackground() }
            if p == .active { model.becameActive() }
        }
    }
}
