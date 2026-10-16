// Translating: TranslateGemma (and EuroLLM where nothing else fits) through
// llama.cpp, built here from its pinned release with llama.cpp's own Android
// settings: every CPU variant built, the best one the phone has chosen when it
// starts, so a budget phone runs the slower path instead of crashing.
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "com.snepssen.translating"
    compileSdk = 36
    ndkVersion = "30.0.16248370"
    defaultConfig {
        minSdk = 29
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        ndk { abiFilters += "arm64-v8a" }
        externalNativeBuild {
            cmake {
                arguments += listOf("-DCMAKE_BUILD_TYPE=Release", "-DANDROID_STL=c++_shared")
            }
        }
    }
    externalNativeBuild { cmake { path = file("src/main/cpp/CMakeLists.txt"); version = "3.31.0" } }
    // The CPU variants are loaded from the app's native library folder, so
    // the libraries must be unpacked there, as llama.cpp's own Android app does.
    packaging { jniLibs { useLegacyPackaging = true } }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    testImplementation(libs.junit)
    testImplementation("org.json:json:20250517")
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.ext.junit)
    androidTestImplementation(libs.junit)
}
