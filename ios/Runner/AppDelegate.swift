import Flutter
import UIKit
import WebKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let sharedFitIntakeBridge = SharedFitIntakeBridge.shared

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    let intakeResult = sharedFitIntakeBridge.publishFiles(
      urls: [url],
      sourcePlatform: "ios",
      storeAsInitial: false
    )
    switch intakeResult {
    case .notHandled:
      return super.application(app, open: url, options: options)
    case .handledSuccess, .handledFailure:
      return true
    }
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    sharedFitIntakeBridge.configure(binaryMessenger: engineBridge.applicationRegistrar.messenger())

    // Never reach for `window` here: after adopting UIScene the window is owned by the
    // scene, so `AppDelegate.window` is nil and a forced cast would trap while the
    // storyboard is still instantiating the view controller. The view controller's
    // binary messenger is the engine's messenger anyway, so take it from the engine.
    let cookieChannel = FlutterMethodChannel(
      name: "onelap_strava_sync/cookie",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    cookieChannel.setMethodCallHandler { (call, result) in
      if call.method == "getCookies" {
        guard let urlStr = call.arguments as? String,
              let url = URL(string: urlStr) else {
          result("")
          return
        }
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
          let filtered = cookies.filter { cookie in
            cookie.domain.lowercased().contains("strava.com")
          }
          let cookieString = filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
          result(cookieString)
        }
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
