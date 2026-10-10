package com.infinitybank.infinitycore

import android.content.Context
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.infinitycore/device"

    /// Controls the native location foreground service. Kept on its own channel
    /// so the existing device-integrity surface is untouched.
    private val locationChannelName = "com.infinitycore/location_service"

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, locationChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val token = call.argument<String>("accessToken")
                        val supabaseUrl = call.argument<String>("supabaseUrl")
                        val rpcPath = call.argument<String>("rpcPath")
                            ?: "/rest/v1/rpc/record_employee_location"
                        val anonKey = call.argument<String>("anonKey") ?: ""
                        if (token.isNullOrBlank() || supabaseUrl.isNullOrBlank()) {
                            // Never start a service that cannot attribute its
                            // own data; LocationTrackingService re-evaluates.
                            result.error("NO_SESSION", "Missing session for tracking", null)
                        } else {
                            LocationForegroundService.start(this, token, supabaseUrl, rpcPath, anonKey)
                            result.success(true)
                        }
                    }
                    "stop" -> {
                        LocationForegroundService.stop(this)
                        result.success(true)
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
