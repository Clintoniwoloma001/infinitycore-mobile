# ============================================================================
# infinitycore release ProGuard / R8 keep rules
# ============================================================================
# WHY THIS FILE EXISTS
#   Flutter forces `releaseBuildType.isMinifyEnabled = true` for release builds
#   (FlutterPlugin.kt), so every release APK/AAB runs R8. R8 in AGP's default
#   FULL mode strips classes that are only referenced reflectively. Without the
#   rules below the release build installs but CRASHES ON LAUNCH with:
#       java.lang.RuntimeException: Unable to get provider
#       androidx.startup.InitializationProvider: ... Failed to create an
#       instance of class androidx.work.impl.WorkDatabase
#   (WorkManager -> Room instantiates its generated *_Impl database via
#   reflection; R8 removed the no-arg constructor). This file is wired in
#   automatically by the Flutter Gradle plugin (FlutterPlugin.kt reads
#   android/app/proguard-rules.pro when it exists).
#
# RULES ARE ADDITIVE ONLY. Nothing here renames or hides a public API.
# ============================================================================

# --- WorkManager + Room (root cause of the 1.1.7+18 launch crash) ----------
# WorkManager's WorkManagerInitializer builds a Room database at process start.
# Room reflects on the generated <Db>_Impl class and calls its no-arg
# constructor, so both the class and that constructor must survive R8.
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class androidx.work.impl.WorkDatabase { *; }
-keep class androidx.work.impl.WorkDatabase_Impl { <init>(); }
-dontwarn androidx.work.**

# --- sqflite (local SQLite, offline queue) ---------------------------------
-keep class com.tekartik.sqflite.** { *; }

# --- connectivity_plus / battery_plus / geolocator -------------------------
# Platform channels resolve by fully-qualified class name at runtime.
-keep class dev.fluttercommunity.plus.connectivity.** { *; }
-keep class dev.fluttercommunity.plus.battery.** { *; }
-keep class com.baseflow.geolocator.** { *; }

# --- Shorebird code push ----------------------------------------------------
# Shorebird's updater resolves classes and reads its bundled shorebird.yaml
# asset; keep the plugin surface so a patch can be validated and applied.
-keep class app.shorebird.** { *; }
-keep class io.shorebird.** { *; }

# --- flutter_local_notifications / local_auth (biometric attendance) -------
-keep class com.dexterous.** { *; }
-keep class io.flutter.plugins.localauth.** { *; }

# --- Google Play services location (geolocator backend) --------------------
# Referenced reflectively by the fused provider on some devices.
-dontwarn com.google.android.gms.**
