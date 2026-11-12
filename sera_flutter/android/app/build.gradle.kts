import java.util.Properties
import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Credentials stay outside the deliverable source tree. Relative storeFile paths
// are resolved next to key.properties, matching the setup script's output.
val signingPropertiesPath = providers.gradleProperty("SERA_SIGNING_PROPERTIES")
    .orElse(providers.environmentVariable("SERA_SIGNING_PROPERTIES"))
    .orElse("../.local/signing/key.properties")
val signingPropertiesFile = rootProject.file(signingPropertiesPath.get())
val signingProperties = Properties().apply {
    if (signingPropertiesFile.isFile) signingPropertiesFile.inputStream().use { load(it) }
}
val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (releaseRequested) {
    if (!signingPropertiesFile.isFile) {
        throw GradleException("Release signing is not configured. Run the signing setup script or set SERA_SIGNING_PROPERTIES to your private key.properties file.")
    }
    for (name in listOf("storeFile", "storePassword", "keyAlias", "keyPassword")) {
        if (signingProperties.getProperty(name).isNullOrBlank()) {
            throw GradleException("Release signing configuration is missing required field: $name")
        }
    }
}

android {
    namespace = "com.sera.sera_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // QA has its own sandbox so integration_test cannot replace or remove
        // the signed user installation. Release keeps the stable application ID.
        applicationId = if (!releaseRequested &&
            providers.environmentVariable("SERA_ANDROID_QA").orNull == "1") {
            "com.sera.sera_flutter.qa"
        } else {
            "com.sera.sera_flutter"
        }
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
            if (signingPropertiesFile.isFile) {
                storeFile = signingProperties.getProperty("storeFile")?.let { path ->
                    val file = File(path)
                    if (file.isAbsolute) file else File(signingPropertiesFile.parentFile, path)
                }
                storePassword = signingProperties.getProperty("storePassword")
                keyAlias = signingProperties.getProperty("keyAlias")
                keyPassword = signingProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
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
