import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.alhikmeh.nots"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.alhikmeh.nots"
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

    // One fixed signing key for every release build, so a new APK installs
    // over the previous one and keeps the user's books and writing (a new
    // random key on each CI run forces an uninstall, which deletes them).
    // CI passes the key through environment variables (GitHub secrets);
    // locally, android/key.properties may point to it. Without either the
    // debug key is used.
    val keyProps = Properties().apply {
        val f = rootProject.file("key.properties")
        if (f.exists()) f.inputStream().use { load(it) }
    }
    val storePath = System.getenv("NOTS_KEYSTORE") ?: keyProps.getProperty("storeFile")
    val storePass = System.getenv("NOTS_KEYSTORE_PASSWORD") ?: keyProps.getProperty("storePassword")
    val alias = System.getenv("NOTS_KEY_ALIAS") ?: keyProps.getProperty("keyAlias")
    val hasReleaseKey = storePath != null && storePass != null && alias != null && file(storePath).exists()

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(storePath!!)
                storePassword = storePass
                keyAlias = alias
                keyPassword = System.getenv("NOTS_KEYSTORE_PASSWORD") ?: keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
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
