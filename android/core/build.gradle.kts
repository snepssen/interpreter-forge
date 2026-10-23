// The interpreter's own logic, decided without a model: the segmenter, clock
// times, language evidence, echoes, catch-up and the quality checks. Plain
// Kotlin, so its tests run anywhere in seconds: the iPhone app's
// InterpreterCore, held to the same cases its tccheck holds it to.
plugins {
    alias(libs.plugins.kotlin.jvm)
}

// Built with the Java 21 the project uses, as Java 17 bytecode like the Android modules.
java { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

dependencies {
    implementation(libs.coroutines.core)
    testImplementation(libs.junit)
    testImplementation(libs.coroutines.core)
    // Only its JSON tree, to read ../../cases; no compiler plugin needed.
    testImplementation(libs.serialization.json)
}
