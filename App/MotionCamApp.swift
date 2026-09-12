import SwiftUI

@main
struct MotionCamApp: App {
    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG && targetEnvironment(simulator)
                if ProcessInfo.processInfo.arguments.contains("--library") { RecordingLibraryView() }
                else { CameraView() }
                #else
                CameraView()
                #endif
            }.preferredColorScheme(.dark).tint(AppTheme.accent)
        }
    }
}
