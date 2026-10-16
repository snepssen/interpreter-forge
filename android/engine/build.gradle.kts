// The engine: the interpreter as the phone runs it. Hearing, the core's
// decisions, translating and the voice, tied into one live loop, as
// InterpreterEngine is on the iPhone.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.snepssen.engine"
    compileSdk = 36
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
    }
    // Only 64-bit ARM ships; sherpa-onnx's x86 slice carries its own ONNX Runtime.
    // llama.cpp's CPU variants are loaded from the native library folder.
    packaging {
        jniLibs { excludes += listOf("lib/x86/**", "lib/x86_64/**", "lib/armeabi-v7a/**"); useLegacyPackaging = true }
    }
    // Silero VAD ships in the app (2 MB); scripts/fetch-hearing.sh fetches it.
    sourceSets { getByName("main").assets.srcDir(layout.buildDirectory.dir("bundled").get().asFile) }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

val bundled by tasks.registering(Copy::class) {
    from(rootDir.resolve("../models/android/silero_vad_v5.onnx"))
    into(layout.buildDirectory.dir("bundled"))
    doFirst { check(rootDir.resolve("../models/android/silero_vad_v5.onnx").exists()) { "run scripts/fetch-hearing.sh first" } }
}
tasks.named("preBuild") { dependsOn(bundled) }

dependencies {
    api(project(":core"))
    api(project(":hearing"))
    api(project(":translating"))
    api(project(":voice"))
    implementation(libs.coroutines.android)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.junit)
}
