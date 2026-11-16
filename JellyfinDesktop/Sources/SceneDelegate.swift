import UIKit

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        let window = UIWindow(windowScene: windowScene)
        window.backgroundColor = UIColor(red: 0x10 / 255.0, green: 0x10 / 255.0, blue: 0x10 / 255.0, alpha: 1.0)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = MainViewController()
        self.window = window
        window.makeKeyAndVisible()
    }
}
