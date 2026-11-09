import Flutter
import UIKit
import AVFoundation
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate {
  // Held so notification-tap callbacks can be forwarded to the web page.
  private var notificationChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    configureAudioSession()
    configureNotifications()
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    try? AVAudioSession.sharedInstance().setActive(true)
  }

  private func configureNotifications() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    // Do NOT request authorization at launch: the OpenChat web UI asks when
    // the user is ready (its own "Enable browser notifications" button /
    // after sign-in).  The JS bridge polyfill forwards that request here.
    // Install the Dart <-> Swift channel once the Flutter view exists.
    // Newer Flutter iOS templates use a UIScene/SceneDelegate instead of a
    // storyboard, so probe both locations.
    installNotificationChannel(attempt: 0)
  }

  private func installNotificationChannel(attempt: Int) {
    var messenger: FlutterBinaryMessenger?
    // Pre-UIScene templates: AppDelegate owns the window.
    if let controller = self.window?.rootViewController as? FlutterViewController {
      messenger = controller.binaryMessenger
    }
    // UIScene templates: find the foreground window scene.
    if messenger == nil {
      for scene in UIApplication.shared.connectedScenes {
        if let windowScene = scene as? UIWindowScene,
           let window = windowScene.windows.first,
           let controller = window.rootViewController as? FlutterViewController {
          messenger = controller.binaryMessenger
          break
        }
      }
    }
    guard let binaryMessenger = messenger else {
      // Flutter view is not up yet - retry a few times (0.2s apart).
      if attempt < 15 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
          self?.installNotificationChannel(attempt: attempt + 1)
        }
      } else {
        NSLog("OpenChat: could not install the notification channel (Flutter view not found)")
      }
      return
    }
    let channel = FlutterMethodChannel(name: "openchat/notifications", binaryMessenger: binaryMessenger)
    notificationChannel = channel
    channel.setMethodCallHandler { call, result in
      let center = UNUserNotificationCenter.current()
      switch call.method {
      case "requestPermission":
        center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in
          center.getNotificationSettings { settings in
            let status = Self.authorizationLabel(settings.authorizationStatus)
            DispatchQueue.main.async { result(status) }
          }
        }
      case "getPermission":
        center.getNotificationSettings { settings in
          let status = Self.authorizationLabel(settings.authorizationStatus)
          DispatchQueue.main.async { result(status) }
        }
      case "show":
        let args = call.arguments as? [String: Any]
        let content = UNMutableNotificationContent()
        content.title = (args?["title"] as? String) ?? "OpenChat"
        content.body = (args?["body"] as? String) ?? ""
        content.sound = .default
        content.threadIdentifier = "openchat"
        let tag = (args?["tag"] as? String) ?? ""
        let identifier = tag.isEmpty ? UUID().uuidString : tag
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
          DispatchQueue.main.async {
            if let error = error {
              NSLog("OpenChat: notification delivery failed: \(error)")
              result(false)
            } else {
              result(true)
            }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func authorizationLabel(_ status: UNAuthorizationStatus) -> String {
    switch status {
    case .authorized, .provisional, .ephemeral: return "granted"
    case .denied: return "denied"
    default: return "default"
    }
  }

  private func configureAudioSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      // .playAndRecord lets the same session play music/videos and record
      // voice messages.  .defaultToSpeaker keeps playback on the speaker, and
      // the category is not silenced by the iPhone mute switch.
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [
          .defaultToSpeaker,
          .allowBluetooth,
          .allowBluetoothA2DP,
          .allowAirPlay,
          .mixWithOthers,
        ]
      )
      try session.setActive(true)
    } catch {
      NSLog("OpenChat audio session error: \(error)")
    }

    NotificationCenter.default.addObserver(
      forName: AVAudioSession.interruptionNotification,
      object: session,
      queue: .main
    ) { notification in
      guard
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let type = AVAudioSession.InterruptionType(rawValue: raw)
      else { return }
      if type == .ended {
        try? session.setActive(true)
      }
    }
  }
}

// FlutterAppDelegate already conforms to UNUserNotificationCenterDelegate,
// so this extension only REPLACES the two delegate methods (they take
// precedence over the inherited implementation) - hence `override`.
// Foreground presentation: in background iOS shows the banner on its own.
// In foreground the page usually renders its own toast, but this also keeps
// the user-configured "background-only toasts" working - the banner is the
// only signal then.  Tapping a banner forwards the notification identifier
// (the web UI's `tag`, e.g. "openchat-12345") to Dart -> JavaScript, which
// runs the web page's own onclick handler (navigation, etc.).
extension AppDelegate {
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.sound, .badge, .banner, .list])
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    notificationChannel?.invokeMethod(
      "notificationTapped",
      arguments: response.notification.request.identifier
    )
    completionHandler()
  }
}
