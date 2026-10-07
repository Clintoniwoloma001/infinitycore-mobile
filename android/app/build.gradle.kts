import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// RELEASE SIGNING CREDENTIALS
//
// The passwords live in android/key.properties, which is gitignored and never
// committed. Reading them here rather than inlining them keeps the keystore
// usable without leaking the secrets into the repository.
//
// `storeFile` in that file is relative to android/app, so the `../upload-
// keystore.jks` below resolves to android/upload-keystore.jks - the same file
// Shorebird signs with, which is what makes an OTA patch installable.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
} else {
    // Fail loudly only when a RELEASE is actually assembled. A debug build must
    // keep working on a checkout with no credentials at all, otherwise every
    // contributor would need the production keystore to run the app locally.
    logger.warn(
        "android/key.properties not found - release builds will NOT be signed. " +
            "Copy the template and fill in the credentials before releasing.",
    )
}

android {
    namespace = "com.infinitybank.infinitycore"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.infinitybank.infinitycore"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = 34
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // The RELEASE KEY, not the debug key. This must match the key the
            // current Shorebird release was signed with, otherwise Android
            // rejects the OTA patch with a signature mismatch and the update
            // never installs. Debug-keyed releases also cannot be replaced by
            // an update on a device that installed a store build.
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                // No credentials on this machine. Kept on debug so a local
                // `flutter run --release` still works; such a build is NOT
                // distributable and must never be pushed to Shorebird.
                signingConfigs.getByName("debug")
            }
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
    // Required by local_auth (biometric attendance) for core library desugaring.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
