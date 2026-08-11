import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

fun signingCredential(name: String): String? {
    val fromFile = keystoreProperties[name]?.toString()?.trim()
    if (!fromFile.isNullOrEmpty()) return fromFile
    val envName = when (name) {
        "storePassword" -> "ANDROID_KEYSTORE_PASSWORD"
        "keyPassword" -> "ANDROID_KEY_PASSWORD"
        "keyAlias" -> "ANDROID_KEY_ALIAS"
        "storeFile" -> "ANDROID_KEYSTORE_PATH"
        else -> null
    }
    return envName?.let { System.getenv(it)?.trim() }?.takeIf { it.isNotEmpty() }
}

val releaseKeyAlias = signingCredential("keyAlias")
val releaseKeyPassword = signingCredential("keyPassword") ?: signingCredential("storePassword")
val releaseStorePassword = signingCredential("storePassword")
val releaseStoreFile = signingCredential("storeFile")?.let { file(it) }
    ?: rootProject.file("app/upload-keystore.jks").takeIf { it.exists() }

val hasReleaseSigning = releaseKeyAlias != null &&
    releaseKeyPassword != null &&
    releaseStorePassword != null &&
    releaseStoreFile != null

android {
    namespace = "com.u_panel"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.u_panel"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            // ARM phones/tablets + x86/x86_64 emulators and Intel devices.
            abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
        }
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = releaseKeyAlias!!
                keyPassword = releaseKeyPassword!!
                storeFile = releaseStoreFile!!
                storePassword = releaseStorePassword!!
            }
        }
    }

    buildTypes {
        release {
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
        debug {
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    // Ensures Gson TypeToken generic signatures survive R8 full mode (AGP 8+).
    implementation("com.google.code.gson:gson:2.11.0")
}
