plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.cloudbox.cloudbox"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "dev.cloudbox.cloudbox"
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // The single source of truth is the repository VERSION file (0.01.13.11.26). Neither
        // pubspec.yaml (strict semver) nor Gradle can express that scheme, so we read the file
        // directly and derive both values here. eng/version.ps1 -Check verifies they agree.
        val cloudboxVersion = rootProject.file("../../VERSION").readText().trim()
        versionName = cloudboxVersion
        versionCode = cloudboxVersion.split(".").let { p ->
            require(p.size == 5) { "VERSION must be MAJOR.MINOR.DD.MM.YY, got $cloudboxVersion" }
            (p[4].toInt() * 10000) + (p[3].toInt() * 100) + p[2].toInt()
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
