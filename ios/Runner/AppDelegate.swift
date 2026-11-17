import UIKit
import Flutter
import AVFoundation
import WebKit

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      let login = FlutterMethodChannel(
        name: "pilipala/ieeio_login", binaryMessenger: controller.binaryMessenger
      )
      login.setMethodCallHandler { call, result in
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
          let matching = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            return ["asr.ieeio.com", ".asr.ieeio.com", ".ieeio.com"].contains(domain)
              && cookie.path == "/" && !cookie.value.isEmpty
              && (cookie.expiresDate ?? .distantFuture) > Date()
              && ["token", "workflowToken"].contains(cookie.name)
          }
          switch call.method {
          case "readLoginToken":
            let token = matching.first { $0.name == "token" }
              ?? matching.first { $0.name == "workflowToken" }
            result(token?.value)
          case "clearRejectedLoginToken":
            guard let rejected = call.arguments as? String else {
              result(nil)
              return
            }
            let deletion = DispatchGroup()
            for cookie in matching where cookie.value.removingPercentEncoding == rejected {
              deletion.enter()
              store.delete(cookie) { deletion.leave() }
            }
            deletion.notify(queue: .main) { result(nil) }
          default:
            result(FlutterMethodNotImplemented)
          }
        }
      }
    }
    
    // 设置音频会话类别，确保在静音模式下播放音频
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, options: [.duckOthers])
    } catch {
      print("Failed to set audio session category: \(error)")
    }
    
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
