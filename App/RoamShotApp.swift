import SwiftUI

@main
struct RoamShotApp: App {
    init() { _ = StabilizationOptions.defaults() }
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--commerce-tests") { Color.black }
                else if ProcessInfo.processInfo.arguments.contains("--upgrade") { ProUpgradeView() }
                else if ProcessInfo.processInfo.arguments.contains("--settings") { NavigationStack { StabilizationSettingsView() } }
                else if ProcessInfo.processInfo.arguments.contains("--library") { RecordingLibraryView() }
                else { CameraView() }
                #else
                CameraView()
                #endif
            }.preferredColorScheme(.dark).tint(AppTheme.accent)
        }
    }
}
