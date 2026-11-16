plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.xxhy.ewtclient.ewt_auto_client"
    // file_picker 的传递依赖 flutter_plugin_android_lifecycle 要求 compileSdk >= 36
    // (Flutter 默认值目前为 34, 会导致 :file_picker:checkDebugAarMetadata 失败)
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.xxhy.ewtclient.ewt_auto_client"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // keeplive-framework (KeepLiveService) 要求 minSdk >= 24
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

    // 仅打包 arm64-v8a 架构, 减小 APK 体积。
    // 注意: Flutter 插件默认会清空 abiFilters 并写入全部 ABI,
    // 需配合 android/gradle.properties 中 disable-abi-filtering=true 才生效;
    // 引擎/libapp 的 ABI 由构建命令 --target-platform android-arm64 控制。
    ndk {
        abiFilters += "arm64-v8a"
    }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
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

dependencies {
    // KeepLiveService 保活框架 (https://github.com/Pangu-Immortal/KeepLiveService)
    implementation("io.github.pangu-immortal:keeplive-framework:2.0.1")
}
