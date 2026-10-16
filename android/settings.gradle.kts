pluginManagement {
    repositories { google(); mavenCentral(); gradlePluginPortal() }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google(); mavenCentral()
        // sherpa-onnx publishes its Android library only as a release download;
        // scripts/fetch-hearing.sh puts it here in Maven's layout.
        maven { url = uri("libs-maven") }
    }
}
rootProject.name = "Interpreter"
include(":app", ":core", ":voice", ":hearing", ":translating", ":engine")
