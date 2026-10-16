// Interpreter for Android: the iPhone app's screens in Jetpack Compose over
// the engine (hearing, translating, the voice, the live loop).
plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

android {
    namespace = "com.snepssen.interpreter"
    compileSdk { version = release(37) { minorApiLevel = 2 } }
    defaultConfig {
        applicationId = "com.snepssen.interpreter"
        minSdk = 29
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += "arm64-v8a" }
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
