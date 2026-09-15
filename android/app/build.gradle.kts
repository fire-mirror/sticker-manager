plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.sticker_manager"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    val releaseStoreFile = System.getenv("STICKER_RELEASE_STORE_FILE")
    val releaseStorePassword = System.getenv("STICKER_RELEASE_STORE_PASSWORD")
    val releaseKeyAlias = System.getenv("STICKER_RELEASE_KEY_ALIAS")
    val releaseKeyPassword = System.getenv("STICKER_RELEASE_KEY_PASSWORD")
    val releaseSigningValues = listOf(
        releaseStoreFile,
        releaseStorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    )
    val hasPartialReleaseSigning = releaseSigningValues.any { !it.isNullOrBlank() }
    if (hasPartialReleaseSigning && releaseSigningValues.any { it.isNullOrBlank() }) {
        throw GradleException(
            "STICKER_RELEASE_STORE_FILE, STICKER_RELEASE_STORE_PASSWORD, " +
                "STICKER_RELEASE_KEY_ALIAS and STICKER_RELEASE_KEY_PASSWORD " +
                "must be provided together",
        )
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.sticker_manager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 28
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!releaseStoreFile.isNullOrBlank()) {
            create("release") {
                storeFile = file(releaseStoreFile!!)
                storePassword = releaseStorePassword!!
                keyAlias = releaseKeyAlias!!
                keyPassword = releaseKeyPassword!!
            }
        }
    }

    buildTypes {
        release {
            // Local builds remain runnable without credentials. CI or a
            // release machine can provide the four STICKER_RELEASE_* values.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
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
    implementation("androidx.core:core-ktx:1.13.1")
}
