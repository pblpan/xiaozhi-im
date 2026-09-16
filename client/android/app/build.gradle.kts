import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ⚠️ 固定签名密钥（2026-09-15 修）
// 之前 release 用的是 signingConfigs.getByName("debug")，debug keystore 由构建机器
// 现场随机生成 —— GitHub Actions 每次都是新虚拟机，于是**每一版 CI 出的 APK 签名都不同**，
// 覆盖安装必然报 INSTALL_FAILED_UPDATE_INCOMPATIBLE(-7)。
// 现在改为读取 key.properties（本地/CI 各自提供），指向一把固定的 keystore。
// key.properties 已被 .gitignore 忽略，不入库；CI 上由 secrets 现场解码生成。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.xiaozhi_im_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.xiaozhi_im_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (hasReleaseKeystore) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                // 现有 debug.keystore 实际是 PKCS12 容器，显式声明避免被按扩展名误判成 JKS
                storeType = keystoreProperties.getProperty("storeType") ?: "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            // 有固定密钥就用它；没有（纯本地开发机）才退回 debug，保证仍可构建。
            // ⚠️ 千万别再改回无条件用 debug —— 那会让每台构建机产出不同签名的包。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }

            // ---- 客户端加固 A：R8 代码混淆 + 资源压缩（2026-09-16，任务 #127）----
            // 目的：把反编译出来的东西从"接近源码"变成"读不懂"。
            // 这不是防破解的银弹（真正的硬判据是 AppIntegrity 的签名校验），
            // 但能让"顺手改两行去掉校验"这件事的成本高一个量级。
            //
            // ⚠️ 出问题时的回退开关：把下面两行改回 false 即可（不用动别处）。
            //    混淆的问题特征很明确 —— **编译期全绿，跑起来某个功能才崩**，
            //    所以打开后必须真机过一遍：选文件 / 录音 / 语音 / 音视频通话 / 打开附件。
            isMinifyEnabled = true
            // 资源压缩默认 safe 模式（保守：可能被引用的都留），
            // 比默认更激进会把插件里动态引用的资源删掉。
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
