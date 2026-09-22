import AppKit
import CoordinatedCalendarCore
import SwiftUI

/// Reopens the window when the app is already running and its window has been closed — clicking the Dock
/// icon, or opening the app again. SwiftUI's `openWindow` exists only inside a view, so the view hands it
/// over; without this, closing the window left the app running with no way back to it.
@MainActor
final class CoordinatedCalendarAppDelegate: NSObject, NSApplicationDelegate {
    static var showMainWindow: (() -> Void)?

    /// Closing the window leaves the app running, as its menu bar shows; the Dock icon brings it back.
    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    nonisolated func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        MainActor.assumeIsolated { Self.showMainWindow?() }
        return true
    }
}

struct CoordinatedCalendarApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(CoordinatedCalendarAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = BridgeViewModel()

    var body: some Scene {
        // One window, not a WindowGroup: the app has a single page of settings, and there is nothing to
        // open a second copy of.
        Window("CoordinatedCalendar", id: Self.mainWindowID) {
            MainWindow(viewModel: viewModel)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private struct MainWindow: View {
    @ObservedObject var viewModel: BridgeViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(viewModel: viewModel)
            .frame(minWidth: 1080, minHeight: 660)
            .onAppear {
                CoordinatedCalendarAppDelegate.showMainWindow = {
                    openWindow(id: CoordinatedCalendarApp.mainWindowID)
                    NSApp.activate(ignoringOtherApps: true)
                }
                closeWindowIfRequested()
            }
    }
}

private extension MainWindow {
    /// `-closeWindowAfter <seconds>` closes the window on a timer, the way the red button does. Only a
    /// person can click that button, so this is how closing and reopening is checked without one.
    func closeWindowIfRequested() {
        let seconds = UserDefaults.standard.double(forKey: "closeWindowAfter")
        guard seconds > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.performClose(nil)
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
