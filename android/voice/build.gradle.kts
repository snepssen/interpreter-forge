// The snepssen voice on Android: espeak-ng (built here from the pinned
// revision every voice was trained with), Polyphon (ported from voice-core's
// Swift, held to the same fixtures) and the Piper model on ONNX Runtime.
// It mirrors voice-core, and moves there once it is proven.
plugins {
    alias(libs.plugins.android.library)
}

val voiceCore = rootDir.resolve("../../voice-core")

android {
    namespace = "com.snepssen.voice"
    compileSdk = 36
    ndkVersion = "30.0.16248370"
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild { cmake { arguments += listOf("-DANDROID_STL=c++_static") } }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.31.0" } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    sourceSets {
        // espeak-ng's data and the parity fixtures are voice-core's own,
        // copied in by the tasks below rather than kept twice.
        getByName("main").assets.srcDir(layout.buildDirectory.dir("voiceCoreAssets").get().asFile)
        getByName("main").assets.srcDir(layout.buildDirectory.dir("polyglotVoice").get().asFile)
        getByName("androidTest").assets.srcDir(layout.buildDirectory.dir("voiceCoreFixtures").get().asFile)
    }
}

val voiceCoreAssets by tasks.registering(Copy::class) {
    from(voiceCore.resolve("Sources/VoiceCore/Resources")) { include("espeak-ng-data/**") }
    into(layout.buildDirectory.dir("voiceCoreAssets"))
}
val voiceCoreFixtures by tasks.registering(Copy::class) {
    from(voiceCore.resolve("Tests/VoiceCoreTests/Fixtures"))
    into(layout.buildDirectory.dir("voiceCoreFixtures/fixtures"))
}
// The polyglot voice, shipped in the app: the same newest export or release
// the Apple builds bundle (apple/scripts/polyglot-voice.sh).
val polyglotVoice by tasks.registering(Copy::class) {
    val model = providers.exec { commandLine(rootDir.resolve("../apple/scripts/polyglot-voice.sh").path) }
        .standardOutput.asText.map { File(it.trim()) }
    from(model) { rename { "snepssen-polyglot.onnx" } }
    from(model.map { File(it.path + ".json") }) { rename { "snepssen-polyglot.onnx.json" } }
    into(layout.buildDirectory.dir("polyglotVoice/voice"))
}
tasks.named("preBuild") { dependsOn(voiceCoreAssets, voiceCoreFixtures, polyglotVoice) }

dependencies {
    implementation(libs.onnxruntime.android)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.junit)
}
