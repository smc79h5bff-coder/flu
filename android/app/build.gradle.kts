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

// ===== 把 APK 复制到 Flutter 期望的目录 =====
tasks.register("syncFlutterApks") {
    doLast {
        val cliApkDir = file("${rootProject.projectDir.parentFile}/build/app/outputs/flutter-apk")
        cliApkDir.mkdirs()
        listOf("prod", "coexist").forEach { flavor ->
            val src = file("${buildDir}/outputs/apk/$flavor/release/app-$flavor-release.apk")
            if (src.exists()) {
                src.copyTo(File(cliApkDir, "app-$flavor-release.apk"), overwrite = true)
                println("[patch] copied ${src.name}")
            } else {
                println("[patch] missing ${src.absolutePath}")
            }
        }
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
