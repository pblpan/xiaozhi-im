# ============================================================
# R8 / ProGuard 规则（客户端加固，2026-09-16，任务 #127）
#
# 打开混淆后**只有真实产物才暴露问题**：编译期一切正常，运行到某个功能才崩
# （典型是插件用反射/JNI 找类名，被改名之后就找不到了）。所以下面的 keep
# 不是"抄来的最佳实践"，而是按**本工程实际用到的插件**逐条列的 ——
# 插件清单以 android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java
# 为准（那份文件是 Flutter 自动生成的，是"到底装了哪些原生插件"的唯一事实来源）。
#
# ⚠️ 新增插件后：先看它在 Android 侧有没有 JNI / 反射 / 动态类名，有就补一条 keep，
#    否则就会出现"新功能一进去就崩，Debug 包却好好的"。
# ============================================================

# ---- 本工程自己的类 ----
# MainActivity 是入口（清单里声明了，R8 会自动保）；
# AppIntegrity 由 MethodChannel 按名字调用，必须显式保留。
-keep class com.example.xiaozhi_im_client.** { *; }

# ---- Flutter 引擎与插件注册表 ----
# 引擎通过 JNI 回调 Dart 侧入口，类名/方法名都不能改。
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# ---- flutter_webrtc：JNI 上调用得最多的一个 ----
# org.webrtc 是原生库（libjingle_peerconnection_so.so）的 Java 门面，
# 原生侧按**完整类名+方法名**去反查，改了名就会 UnsatisfiedLinkError。
-keep class org.webrtc.** { *; }
-keep class com.cloudwebrtc.webrtc.** { *; }
-dontwarn org.webrtc.**

# ---- record（语音消息录制）----
-keep class com.llfbandit.record.** { *; }

# ---- 其余插件：多数是 MethodChannel 显式调用，但保留类名代价很小，值得换稳 ----
-keep class com.mr.flutter.plugin.filepicker.** { *; }      # file_picker
-keep class com.crazecoder.openfile.** { *; }               # open_filex
-keep class xyz.luan.audioplayers.** { *; }                 # audioplayers
-keep class com.github.dart_lang.jni.** { *; }              # dart:jni（供 record 等使用）
-keep class com.github.dart_lang.jni_flutter.** { *; }

# ---- 注解/泛型签名：R8 默认会剥掉，缺了会在运行期报
#      "ClassNotFoundException / NoSuchMethodError" 这类莫名其妙的问题 ----
-keepattributes *Annotation*, Signature, InnerClasses, EnclosingMethod

# ---- 不要因为可选依赖缺失而构建失败 ----
# 这些库在 Android 上都只用到一小部分，缺的类不会被真正执行。
-dontwarn javax.annotation.**
-dontwarn kotlin.**
-dontwarn kotlinx.**
-dontwarn org.slf4j.**
-dontwarn com.google.errorprone.**
-dontwarn org.checkerframework.**
