import SwiftUI

@main
struct MotionCamApp: App {
    var body: some Scene { WindowGroup { CameraView().preferredColorScheme(.dark) } }
}
