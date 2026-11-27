import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// A build without this ID hides the saved Google account and cannot sign in.
// Check every APK variant before Flutter compilation, including local debug.
val verifyGoogleConfiguration by tasks.registering {
    val definitions = providers.gradleProperty("dart-defines")
    inputs.property("dart-defines", definitions.orElse(""))
    doLast {
        val values = try {
            definitions.orNull.orEmpty().split(',').filter { it.isNotEmpty() }.associate {
                val decoded = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
                decoded.substringBefore('=') to decoded.substringAfter('=', "")
            }
        } catch (_: IllegalArgumentException) {
            throw GradleException("Invalid encoded Dart build configuration.")
        }
        val projectId = values["ANTIRKN_GOOGLE_PROJECT_ID"].orEmpty()
        if (!Regex("^[a-z][a-z0-9-]{4,61}[a-z0-9]$").matches(projectId)) {
            throw GradleException(
                "Google Project ID is missing or invalid. Build with " +
                    "--dart-define-from-file=<external Google build defines JSON>. " +
                    "See docs/google-drive-setup.md; never include Desktop client secrets."
            )
        }
    }
}

// Release signing for local builds: android/key.properties (storeFile,
// storePassword, keyAlias, keyPassword) or the ANTIRKN_ANDROID_* variables
// below. Without either, release builds fall back to the debug key so local
// `flutter build apk` keeps working. CI never signs here: the release workflow
// re-signs APKs with apksigner in its protected `release` environment.
val releaseSigning: Map<String, String>? = run {
    val file = rootProject.file("key.properties")
    val values = if (file.isFile) {
        val properties = Properties()
        file.inputStream().use { properties.load(it) }
        listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
            .associateWith { properties.getProperty(it).orEmpty() }
    } else {
        mapOf(
            "storeFile" to "ANTIRKN_ANDROID_KEYSTORE",
            "storePassword" to "ANTIRKN_ANDROID_KEYSTORE_PASSWORD",
            "keyAlias" to "ANTIRKN_ANDROID_KEY_ALIAS",
            "keyPassword" to "ANTIRKN_ANDROID_KEY_PASSWORD",
        ).mapValues { System.getenv(it.value).orEmpty() }
    }
    when {
        values.values.all { it.isEmpty() } -> null
        values.values.any { it.isEmpty() } -> throw GradleException(
            "Release signing is incomplete: set " +
                values.filterValues { it.isEmpty() }.keys.joinToString() + "."
        )
        else -> values
    }
}

tasks.matching { it.name.startsWith("compileFlutterBuild") }.configureEach {
    dependsOn(verifyGoogleConfiguration)
}

android {
    namespace = "org.antirkn.antirkn_manager"
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
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "org.antirkn.antirkn_manager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        testInstrumentationRunner = "org.antirkn.antirkn_manager.MihomoRuntimeTest"
    }

    testBuildType = "release"

    signingConfigs {
        releaseSigning?.let { values ->
            create("release") {
                storeFile = rootProject.file(values.getValue("storeFile"))
                storePassword = values.getValue("storePassword")
                keyAlias = values.getValue("keyAlias")
                keyPassword = values.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (releaseSigning != null) "release" else "debug")
        }
    }
}

flutter {
    source = "../.."
}

// Release versionCode = build * 10 + ABI id (universal 0, armeabi-v7a 1,
// arm64-v8a 2, x86_64 3), so every APK of a newer build outranks every APK of
// an older one and a device may switch between split and universal APKs.
// This replaces Flutter's ABI * 1000 + build offset: the Flutter plugin
// registers its applicationVariants action when it is applied (plugins block),
// this one is registered later, so for every variant it runs after Flutter's.
// Debug and profile builds keep the plain build number.
// tool/ci/android_release.py verifies the result in the built APKs.
val releaseAbiIds = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    if (buildType.name != "release") return@configureEach
    val build = versionCode
    if (build < 1 || build > 209_999_999) {
        throw GradleException("Build number $build does not fit versionCode = build * 10 + ABI id.")
    }
    outputs.forEach { output ->
        @Suppress("DEPRECATION")
        val apk = output as com.android.build.gradle.api.ApkVariantOutput
        @Suppress("DEPRECATION")
        val abi = apk.getFilter(com.android.build.VariantOutput.FilterType.ABI)
        val id = if (abi == null) 0 else releaseAbiIds[abi] ?: throw GradleException("Unsupported ABI split: $abi")
        apk.versionCodeOverride = build * 10 + id
    }
}

dependencies {
    implementation("com.google.android.gms:play-services-auth:22.0.0")
}

// All selected Flutter ABIs include the same pinned core. Generated binaries stay
// under build/, and the task input digest avoids rebuilding unchanged Go code.
val mihomoGenerated = layout.buildDirectory.dir("generated/mihomo")
android.sourceSets.getByName("main") {
    jniLibs.srcDir(mihomoGenerated.map { it.dir("jniLibs") })
    assets.srcDir(mihomoGenerated.map { it.dir("assets") })
}
val buildMihomo by tasks.registering {
    doLast {
        val root = rootProject.projectDir.resolve("../../..").canonicalFile
        val selected = providers.gradleProperty("target-platform").orElse("android-arm,android-arm64,android-x64").get().split(',')
        val abis = mapOf("android-arm" to "armeabi-v7a", "android-arm64" to "arm64-v8a", "android-x64" to "x86_64")
        for (platform in selected) {
            val abi = abis[platform] ?: throw GradleException("Unsupported Mihomo ABI: $platform")
            val output = mihomoGenerated.get().file("jniLibs/$abi/libantirkn_mihomo.so").asFile
            val process = ProcessBuilder("python3", root.resolve("tool/build_mihomo.py").path,
                "--target", "android", "--abi", abi,
                "--ndk", android.sdkDirectory.resolve("ndk/${android.ndkVersion}").path,
                "--output", output.path).inheritIO().start()
            if (process.waitFor() != 0) throw GradleException("Mihomo native build failed")
            copy {
                from(output.parentFile.resolve("notices"))
                into(mihomoGenerated.get().dir("assets/mihomo/notices"))
            }
        }
    }
}
tasks.named("preBuild").configure { dependsOn(buildMihomo) }
