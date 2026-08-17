plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.palmpay.palmpay_enroll"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.palmpay.palmpay_enroll"
        // minSdk 24 required by onnxruntime and camera plugins.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Enable multidex for Firebase + ONNX Runtime
        multiDexEnabled = true
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Required on the compile classpath so javac can resolve type annotations
    // referenced by androidx.camera:camera-core (used by the camera plugin's
    // CameraX backend); otherwise compileDebugJavaWithJavac fails with
    // "class file for androidx.concurrent.futures.CallbackToFutureAdapter not found".
    implementation("androidx.concurrent:concurrent-futures:1.1.0")
}
