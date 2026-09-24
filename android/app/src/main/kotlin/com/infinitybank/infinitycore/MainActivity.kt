package com.infinitybank.infinitycore

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.infinitycore/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isMockLocation" -> {
                        result.success(isMockLocationEnabled(this))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isMockLocationEnabled(context: Context): Boolean {
        return try {
            Settings.Secure.getInt(
                context.contentResolver,
                Settings.Secure.ALLOW_MOCK_LOCATION
            ) != 0
        } catch (e: Settings.SettingNotFoundException) {
            false
        }
    }
}
