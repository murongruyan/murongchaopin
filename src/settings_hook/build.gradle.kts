plugins {
    id("com.android.application") version "9.2.1"
}

android {
    namespace = "com.murongchaopin.displayhook"
    compileSdk = 37
    buildToolsVersion = "37.0.0"

    defaultConfig {
        applicationId = "com.murongchaopin.displayhook"
        minSdk = 29
        targetSdk = 37
        versionCode = 29
        versionName = "2.9-api102"
    }

    buildFeatures {
        buildConfig = true
    }

    flavorDimensions += "tier"

    productFlavors {
        create("free") {
            dimension = "tier"
            buildConfigField("boolean", "IS_PREMIUM_BUILD", "false")
        }
        create("premium") {
            dimension = "tier"
            applicationIdSuffix = ".premium"
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
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
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
    from(layout.buildDirectory.file("outputs/apk/free/release/murong-display-hook-free-release.apk"))
    into(rootDir.resolve("../../bin"))
    rename { "display_settings_hook.apk" }
}

tasks.register<Copy>("exportPremiumApk") {
    dependsOn("assemblePremiumRelease")
    from(layout.buildDirectory.file("outputs/apk/premium/release/murong-display-hook-premium-release.apk"))
    into(rootDir.resolve("../../packaging/paid-payload/hooks"))
    rename { "display_premium_hook.apk" }
}
