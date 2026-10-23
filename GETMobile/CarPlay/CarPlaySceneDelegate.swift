import UIKit
import CarPlay

/// Entry point for the CarPlay scene. Registered in Info.plist
/// (UIApplicationSceneManifest -> CPTemplateApplicationSceneSessionRoleApplication)
/// by project.yml. The phone UI is still the SwiftUI WindowGroup; this only
/// handles the car display.
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        Task { @MainActor in
            let controller = CarPlayController(interfaceController: interfaceController)
            self.controller = controller
            controller.start()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        Task { @MainActor in
            self.controller?.stop()
            self.controller = nil
        }
    }
}
