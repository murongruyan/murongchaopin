buildscript {
    dependencies {
        // AGP 9.5's built-in Kotlin defaults to 2.2.10; use the current
        // Kotlin compiler so Java 26 bytecode is available to Android tasks.
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.10")
    }
}

plugins {
    id("com.android.application") version "9.5.0-alpha02"
}

val hookVersionCode = 69

android {
    namespace = "com.murongchaopin.displayhook"
    compileSdk = 37
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "com.murongchaopin.displayhook"
        minSdk = 29
        targetSdk = 37
    }

    buildFeatures {
        buildConfig = true
    }

    flavorDimensions += "tier"

    productFlavors {
        create("free") {
            dimension = "tier"
            versionCode = hookVersionCode
            versionName = "69.0-api102-free-stability"
            buildConfigField("boolean", "IS_PREMIUM_BUILD", "false")
        }
        create("premium") {
            dimension = "tier"
            applicationIdSuffix = ".premium"
            versionCode = hookVersionCode
            versionName = "69.0-api102-paid-display-ui"
            buildConfigField("boolean", "IS_PREMIUM_BUILD", "true")
        }
    }

    sourceSets["main"].apply {
        manifest.srcFile("AndroidManifest.xml")
        java.directories.clear()
        java.directories.add("java")
        resources.directories.clear()
        resources.directories.add("resources")
        res.directories.clear()
        res.directories.add("res")
    }

    sourceSets["free"].apply {
        java.directories.add("java-free")
        resources.directories.clear()
        resources.directories.add("resources-free")
        res.directories.add("res-free")
    }

    sourceSets["premium"].apply {
        java.directories.add("java-premium")
        resources.directories.clear()
        resources.directories.add("resources-premium")
        res.directories.add("res-premium")
    }

    val releaseStoreFile = providers.environmentVariable("MURONG_HOOK_KEYSTORE")
    val releaseStorePassword = providers.environmentVariable("MURONG_HOOK_STORE_PASSWORD")
    val releaseKeyAlias = providers.environmentVariable("MURONG_HOOK_KEY_ALIAS")
    val releaseKeyPassword = providers.environmentVariable("MURONG_HOOK_KEY_PASSWORD")
    val hasReleaseSigning = listOf(
        releaseStoreFile,
        releaseStorePassword,
        releaseKeyAlias,
        releaseKeyPassword,
    ).all { it.isPresent }

    if (hasReleaseSigning) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseStoreFile.get())
                storePassword = releaseStorePassword.get()
                keyAlias = releaseKeyAlias.get()
                keyPassword = releaseKeyPassword.get()
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            isDebuggable = false
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            proguardFiles("proguard-rules.pro")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_26
        targetCompatibility = JavaVersion.VERSION_26
    }

    packaging {
        resources {
            merges += "META-INF/xposed/*"
            excludes += "kotlin/**"
        }
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = false
    }
}

dependencies {
    compileOnly("io.github.libxposed:api:102.0.0")
}

// Research-only experiment: keep the source for reference, but never compile
// it into either distributable variant.
tasks.withType<org.gradle.api.tasks.compile.JavaCompile>().configureEach {
    exclude("**/BilibiliStoryHooks.java")
}

tasks.register<Copy>("exportFreeApk") {
    dependsOn("assembleFreeRelease")
    from(layout.buildDirectory.dir("outputs/apk/free/release")) {
        include("*.apk")
        rename { "display_settings_hook.apk" }
    }
    into(rootDir.resolve("../../bin"))
}

tasks.register<Copy>("exportPremiumApk") {
    dependsOn("assemblePremiumRelease")
    from(layout.buildDirectory.dir("outputs/apk/premium/release")) {
        include("*.apk")
        rename { "display_premium_hook.apk" }
    }
    into(rootDir.resolve("../../packaging/paid-payload/hooks"))
}

tasks.named("exportPremiumApk") {
    doLast {
        // Sidecar version file used by premium_service.sh so boot-time installs
        // only upgrade, never overwrite a newer installed paid hook.
        val out = rootDir.resolve("../../packaging/paid-payload/hooks")
        out.mkdirs()
        out.resolve("display_premium_hook.version").writeText("$hookVersionCode\n")
    }
}
