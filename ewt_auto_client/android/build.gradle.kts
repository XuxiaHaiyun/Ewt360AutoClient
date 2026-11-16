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

// 先注册回调 (必须在 evaluationDependsOn 触发评估之前注册,
// 否则 "Cannot run afterEvaluate when project is already evaluated")
subprojects {
    // 修复 1: 为 Android library 子项目 (Flutter 插件) 强制应用 Kotlin 插件
    // 部分插件 (如 volume_controller 3.6.0) 在 buildscript 中声明了
    // kotlin-gradle-plugin 依赖, 但 build.gradle 中缺少
    // `apply plugin: "kotlin-android"`, 导致 Kotlin 源码不被编译,
    // GeneratedPluginRegistrant.java 找不到插件类。
    // 在 com.android.library 应用时立即补应用 Kotlin 插件 (早于插件
    // build.gradle 中的 compileSdk 语句)。
    project.plugins.withId("com.android.library") {
        if (!project.plugins.hasPlugin("org.jetbrains.kotlin.android")) {
            project.plugins.apply("org.jetbrains.kotlin.android")
        }
    }

    // 修复 2: 强制所有 Android library 子项目 (Flutter 插件) 使用 compileSdk ≥ 36
    // 修复 :file_picker:checkDebugAarMetadata 失败:
    // flutter_plugin_android_lifecycle 要求 compileSdk ≥ 36,
    // 但 file_picker 等插件硬编码 compileSdk 34。
    //
    // ⚠️ 必须用 afterEvaluate: withId 回调在插件应用时触发, 但插件 build.gradle
    //    中的 `compileSdk 34` 在之后才执行会覆盖设置; afterEvaluate 确保在
    //    子项目完全评估后再覆盖。
    // 使用 GroovyObject 互操作避免直接引用 AGP 类型 (根 build.gradle.kts
    // 的编译 classpath 中不含 AGP 类)。
    project.afterEvaluate {
        if (project.plugins.hasPlugin("com.android.library")) {
            val androidExt = project.extensions.findByName("android")
            if (androidExt is groovy.lang.GroovyObject) {
                val current = androidExt.getProperty("compileSdk") as? Int
                if (current == null || current < 36) {
                    androidExt.setProperty("compileSdk", 36)
                }
            }
        }
    }

    // 修复 3: 为缺失 namespace 的插件注入 namespace
    // AGP 8.x 要求 android.namespace 必须显式指定, 旧插件仅通过 AndroidManifest.xml
    // 的 package 属性声明 (已在 AGP 8.x 弃用), 导致构建报错:
    //   "Namespace not specified. Specify a namespace in the module's build file"
    // 从 AndroidManifest.xml 的 package 属性读取并注入到 android.namespace,
    // 仅在 namespace 未设置时执行 (不覆盖已正确配置的插件)。
    project.plugins.withId("com.android.library") {
        val androidExt = project.extensions.findByName("android")
        if (androidExt is groovy.lang.GroovyObject) {
            val ns = androidExt.getProperty("namespace") as? String
            if (ns.isNullOrEmpty()) {
                val manifest = project.file("src/main/AndroidManifest.xml")
                if (manifest.exists()) {
                    val pkg = manifest.readText()
                        .let { Regex("""package="([^"]+)"""").find(it)?.groupValues?.get(1) }
                    if (!pkg.isNullOrEmpty()) {
                        androidExt.setProperty("namespace", pkg)
                    }
                }
            }
        }
    }
}

// 再注册 evaluationDependsOn (会触发 :app 及插件模块评估)
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
