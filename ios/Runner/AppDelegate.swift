import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

    private var gopsPrivacyShield: UIView?

    override func applicationWillResignActive(_ application: UIApplication) {
        super.applicationWillResignActive(application)
        guard let window = window else { return }
        let shield = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        shield.frame = window.bounds
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(shield)
        gopsPrivacyShield = shield
    }

    override func applicationDidBecomeActive(_ application: UIApplication) {
        gopsPrivacyShield?.removeFromSuperview()
        gopsPrivacyShield = nil
        super.applicationDidBecomeActive(application)
    }
}

