plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.docdiff"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    flavorDimensions += "app"

    productFlavors {
        create("prod") {
            dimension = "app"
            applicationId = "com.example.docdiff"
            manifestPlaceholders["appName"] = "DocDiff"
        }
        create("coexist") {
            dimension = "app"
            applicationId = "com.txtdifferent.compare"
            manifestPlaceholders["appName"] = "TXT对比"
        }
    }

    signingConfigs {
        create("release") {
            storeFile = file("release.jks")
            storePassword = "123456"
            keyAlias = "docdiff"
            keyPassword = "123456"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// ===== 把带 flavor 的 APK 复制到 Flutter 期望的目录 =====
val flutterApkDir = file("${buildDir}/outputs/flutter-apk")
val cliApkDir = file("${rootProject.projectDir.parentFile}/build/app/outputs/flutter-apk")

tasks.register<Copy>("syncFlutterApks") {
    // 关键：源目录改成真正的 APK 输出目录（apk/prod/release 等）
    android.applicationVariants.all {
        val variantName = name // 例如 prodRelease
        val flavorName = productFlavors.first().name // prod 或 coexist
        from("${buildDir}/outputs/apk/$flavorName/release") {
            include("*.apk")
            rename { "app-$flavorName-release.apk" }
        }
    }
    into(cliApkDir)
    doFirst {
        cliApkDir.mkdirs()
        println("[patch] syncFlutterApks -> ${cliApkDir.absolutePath}")
    }
    doLast {
        println("[patch] syncFlutterApks done")
    }
}

android.applicationVariants.all {
    val cap = name.replaceFirstChar { it.uppercase() }
    listOf("package$cap", "assemble$cap").forEach { taskName ->
        tasks.matching { it.name == taskName }.all {
            finalizedBy("syncFlutterApks")
        }
    }
}
