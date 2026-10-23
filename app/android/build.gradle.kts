allprojects {
    repositories {
        // 与 settings.gradle.kts 的 pluginManagement 镜像保持一致：
        // dl.google.com 在部分网络不可达，依赖一律先走阿里云镜像。
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/central") }
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
}
subprojects {
    // app 模块的 ndk.abiFilters 不会传播到插件模块：插件（如 :jni）默认仍按全部 ABI
    // 构建原生代码，而容器内 NDK 28 对 armeabi-v7a 等其它 ABI 链接不兼容（-lgcc 缺失），
    // 且 App 本身只发 arm64 包（见 app/build.gradle.kts 的注释）。统一限制为 arm64-v8a。
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
            defaultConfig {
                ndk {
                    abiFilters += "arm64-v8a"
                }
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
