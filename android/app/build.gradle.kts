plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.docdiff"
    compileSdk = flutter.compileSdkVersion
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

// ===== 新增：同步 APK 到 Flutter 期望目录 =====
val flutterOutDir = file("${buildDir}/outputs/flutter-apk")
val cliOutDir = file("${rootProject.projectDir.parentFile}/build/app/outputs/flutter-apk")

tasks.register<Copy>("syncFlutterApks") {
    from(flutterOutDir)
    into(cliOutDir)
    doFirst {
        cliOutDir.mkdirs()
        println("[patch] syncFlutterApks: from=${flutterOutDir} -> to=${cliOutDir}")
    }
    doLast {
        println("[patch] syncFlutterApks: done")
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
