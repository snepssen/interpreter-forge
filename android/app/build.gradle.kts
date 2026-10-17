// Interpreter for Android: the iPhone app's screens in Jetpack Compose over
// the engine (hearing, translating, the voice, the live loop).
import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

// The release key and its password live outside git: keystore.properties
// beside this project, pointing at ~/.android/interpreter-release.jks. Every
// update must be signed with the same key, so both are backed up.
val signing = rootProject.file("keystore.properties").takeIf { it.exists() }?.let { f -> Properties().apply { f.inputStream().use(::load) } }

android {
    namespace = "com.snepssen.interpreter"
    compileSdk { version = release(37) { minorApiLevel = 2 } }
    defaultConfig {
        applicationId = "com.snepssen.interpreter"
        minSdk = 29
        targetSdk = 36
        versionCode = 3
        versionName = "0.2"
        ndk { abiFilters += "arm64-v8a" }
    }
    signingConfigs {
        if (signing != null) create("release") {
            storeFile = file(signing.getProperty("storeFile"))
            storePassword = signing.getProperty("storePassword")
            keyAlias = signing.getProperty("keyAlias")
            keyPassword = signing.getProperty("keyPassword")
        }
    }
    buildTypes {
        release {
            // No shrinking: sherpa-onnx and ONNX Runtime reach their Kotlin
            // classes from native code by name, which R8 would rename away.
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    packaging {
        // Only 64-bit ARM ships; sherpa-onnx's x86 slice carries its own ONNX Runtime.
        // llama.cpp's CPU variants are loaded from the native library folder.
        jniLibs { excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**"); useLegacyPackaging = true }
    }
    // The voice and the VAD are read once into files; no need to squeeze them.
    androidResources { noCompress += listOf("onnx", "json") }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":engine"))
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.core.ktx)
}
