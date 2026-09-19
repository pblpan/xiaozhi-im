import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 固定签名密钥 ─────────────────────────────────────────────
// release 若用 signingConfigs.getByName("debug")，而 debug keystore 是构建机器
// 现场随机生成的 —— 换一台机器（或换一个 CI 虚拟机）出的 APK 签名就不同，
// 员工覆盖安装必然报 INSTALL_FAILED_UPDATE_INCOMPATIBLE(-7)。
// 这里读 key.properties（本地/CI 各自提供，已 gitignore）；**没有这个文件**
// 才退回 debug，保证纯本地也能构建。
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.pblpan.xiaozhi_scanner"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // ⚠️ 独立包名，和小智 IM（com.example.xiaozhi_im_client）**不冲突** ——
        //    员工手机上可以同时装两个，扫码枪不会把 IM 覆盖掉。
        applicationId = "com.pblpan.xiaozhi_scanner"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
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
                // 显式声明容器类型，避免被按扩展名误判成 JKS
                storeType = keystoreProperties.getProperty("storeType") ?: "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // R8 混淆**先不开**。这一版是首次交付，要的是"装上就能扫"；
            // 混淆的问题特征是"编译全绿、跑起来某个功能才崩"，
            // 真机没过一遍就打开等于给自己埋雷。等真机验收完再考虑。
            isMinifyEnabled = false
            // ⚠️ 这两行必须**成对**关掉。AGP 9.x 下只关 minify、不关 shrinkResources
            // 会直接构建失败，而且报错指向的是**根 build.gradle.kts 的一行无关代码**：
            //     * Where: Build file ...\android\build.gradle.kts line: 19
            //     > Removing unused resources requires unused code shrinking
            //       to be turned on.
            // 看着像 `evaluationDependsOn(":app")` 写错了，其实是 release 这边
            // 两个开关不匹配 —— 别去改那个文件。
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // 出站分享要用 androidx.core 的 FileProvider（见 MainActivity.shareFile）。
    // 显式声明：不能指望"某个插件顺带把它带进来"—— 哪天插件换了实现，
    // 这里就会变成一个很难读的编译错误（unresolved reference: FileProvider）。
    implementation("androidx.core:core-ktx:1.13.1")
}

flutter {
    source = "../.."
}
