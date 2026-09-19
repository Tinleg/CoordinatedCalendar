import CoordinatedCalendarCore
import SwiftUI

struct CoordinatedCalendarApp: App {
    @StateObject private var viewModel = BridgeViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@main
enum CoordinatedCalendarMain {
    static func main() async {
        if CommandLineBridge.isCommandLineMode {
            exit(await CommandLineBridge.run())
        }
        CoordinatedCalendarApp.main()
    }
}
