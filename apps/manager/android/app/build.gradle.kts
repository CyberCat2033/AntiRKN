import java.util.Base64

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
