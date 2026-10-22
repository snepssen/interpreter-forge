// ONNX Runtime's one environment, shared by hearing and voice.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.snepssen.ort"
    compileSdk = 36
    defaultConfig { minSdk = 29 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(libs.onnxruntime.android)
}
