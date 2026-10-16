plugins {
    alias(libs.plugins.android.application)
}
android {
    namespace = "com.snepssen.interpreter"
    compileSdk = 36
    defaultConfig { minSdk = 29 }
}
