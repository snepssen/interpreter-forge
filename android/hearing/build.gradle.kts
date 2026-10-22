// Hearing: Silero VAD v5 on ONNX Runtime (the iPhone app's SileroVAD, line
// for line) and Parakeet TDT 0.6B v3 through sherpa-onnx, turned into timed
// words the way the iPhone app turns FluidAudio's tokens into words.
// scripts/fetch-hearing.sh fetches sherpa-onnx and the models.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.snepssen.hearing"
    compileSdk = 36
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
    }
    // Only 64-bit ARM ships; sherpa-onnx's x86 slice carries its own ONNX Runtime.
    packaging { jniLibs { excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**") } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(project(":core"))
    implementation(project(":ort"))
    implementation(libs.onnxruntime.android)
    // The variant with ONNX Runtime linked in: no second libonnxruntime.so.
    implementation(libs.sherpa.onnx)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.junit)
}
