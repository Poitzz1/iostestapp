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
}

// androidx.camera:camera-core (pulled in by the camera plugin's CameraX backend)
// references androidx.concurrent.futures.CallbackToFutureAdapter in type annotations
// but doesn't put it on javac's compile classpath itself, causing
// "class file for androidx.concurrent.futures.CallbackToFutureAdapter not found".
subprojects {
    if (project.name == "camera_android_camerax") {
        project.afterEvaluate {
            dependencies.add("implementation", "androidx.concurrent:concurrent-futures:1.1.0")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
