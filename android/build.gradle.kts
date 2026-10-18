import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")

    tasks.withType<KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(JvmTarget.JVM_17)
        }
    }
    tasks.withType<JavaCompile>().configureEach {
        sourceCompatibility = JavaVersion.VERSION_17.toString()
        targetCompatibility = JavaVersion.VERSION_17.toString()
    }
}

// ===== flutter_js 特殊处理 =====
// flutter_js 插件自身的 Java 编译目标是 11，且它会强制覆盖 compileOptions，
// 导致 Java(11) 和 Kotlin(17) 冲突。这里把它的 Kotlin 也降到 11，两边对齐。
subprojects {
    if (name == "flutter_js") {
        tasks.withType<KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(JvmTarget.JVM_11)
            }
        }
        tasks.withType<JavaCompile>().configureEach {
            sourceCompatibility = JavaVersion.VERSION_11.toString()
            targetCompatibility = JavaVersion.VERSION_11.toString()
        }
    }
}
// ================================

// ===== rive_common 特殊处理 =====
// rive_common 插件的 build.gradle 把 Java 编译目标钉死成 1.8，
// 而全局 Kotlin 是 17，Gradle 报 JVM target 不一致。
// 这里在它自己评估完之后，把 Java 也拉到 17，两边对齐。
subprojects {
    if (name == "rive_common") {
        afterEvaluate {
            tasks.withType<JavaCompile>().configureEach {
                sourceCompatibility = JavaVersion.VERSION_17.toString()
                targetCompatibility = JavaVersion.VERSION_17.toString()
            }
            tasks.withType<KotlinCompile>().configureEach {
                compilerOptions {
                    jvmTarget.set(JvmTarget.JVM_17)
                }
            }
        }
    }
}
// ================================

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
