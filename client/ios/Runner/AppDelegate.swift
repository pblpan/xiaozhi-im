import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // ===== AUDIO SESSION (gen_ios_project.py) =====
    // 配置音频会话：分类 PlayAndRecord + 模式 VoiceChat。
    // ⚠️ 必须在启动时就设，否则点"免提"会被 flutter_webrtc **静默忽略**
    //    （setSpeakerphoneOn 要求分类为 PlayAndRecord，见 AudioUtils.m:68）。
    //    完整依据与各项选项的后果见 docs/iOS音频会话设计.md。
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
      )
    } catch {
      NSLog("[xiaozhi] AVAudioSession 配置失败: \(error)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
