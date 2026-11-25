plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.jondhale.iteam"
    compileSdk = 36
    defaultConfig {
        // ITEAM_RELAY=1 builds "iTeam Next": a separate app (installs beside iTeam) that uses our relay server.
        val relay = System.getenv("ITEAM_RELAY") == "1"
        applicationId = if (relay) "com.jondhale.iteam.next" else "com.jondhale.iteam"
        manifestPlaceholders["appLabel"] = if (relay) "iTeam Next" else "iTeam Chat"
        buildConfigField("boolean", "RELAY", relay.toString())
        buildConfigField("String", "RELAY_URL", "\"" + (System.getenv("RELAY_URL") ?: "https://relay.iteamchat.in") + "\"")
        buildConfigField("String", "GOOGLE_WEB_CLIENT_ID", "\"" + (System.getenv("GOOGLE_WEB_CLIENT_ID") ?: "") + "\"")
        minSdk = 28
        targetSdk = 36
        // One rising number for every build (sideload APK and Play bundle): minutes since 1 Jan 2025.
        versionCode = (System.getenv("VERSION_CODE") ?: System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = System.getenv("VERSION_NAME") ?: ("1.0." + (System.getenv("GITHUB_RUN_NUMBER") ?: "0"))
        // CloudKit web API token (public by design, like any CloudKit JS page) and environment.
        buildConfigField("String", "CK_TOKEN", "\"" + (System.getenv("CK_API_TOKEN") ?: "") + "\"")
        buildConfigField("String", "CK_ENV", "\"" + (System.getenv("CK_ENV") ?: "production") + "\"")
    }
    signingConfigs {
        create("release") {
            val ks = System.getenv("KEYSTORE_FILE")
            if (ks != null) {
                storeFile = file(ks)
                storePassword = System.getenv("KEYSTORE_PASSWORD")
                keyAlias = "iteam"
                keyPassword = System.getenv("KEYSTORE_PASSWORD")
            }
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (System.getenv("KEYSTORE_FILE") != null) signingConfigs.getByName("release") else signingConfigs.getByName("debug")
        }
    }
    buildFeatures { compose = true; buildConfig = true }
    compileOptions { sourceCompatibility = JavaVersion.VERSION_17; targetCompatibility = JavaVersion.VERSION_17 }
    kotlinOptions { jvmTarget = "17" }
    packaging { resources { excludes += setOf("META-INF/versions/9/OSGI-INF/MANIFEST.MF", "META-INF/*.kotlin_module") } }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(bom)
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.ui:ui")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.work:work-runtime-ktx:2.10.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("org.bouncycastle:bcprov-jdk18on:1.79")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("androidx.credentials:credentials:1.3.0")
    implementation("androidx.credentials:credentials-play-services-auth:1.3.0")
    implementation("com.google.android.libraries.identity.googleid:googleid:1.1.1")
}
