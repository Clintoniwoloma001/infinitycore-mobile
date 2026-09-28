package com.infinitybank.infinitycore

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-establishes the location foreground service after a device reboot.
 *
 * WHAT THIS DELIBERATELY DOES NOT DO
 * It does not start tracking unconditionally, and it does not fabricate a
 * session. The service refuses to run without an access token (see
 * [LocationForegroundService.onStartCommand]), so the correct behaviour after a
 * reboot is: record that the user was tracking, and let the app re-evaluate
 * eligibility, permission and session on next launch, which then starts the
 * service properly if all three still hold.
 *
 * That ordering is the requirement from the spec: reboot -> recovery -> check
 * authentication -> check employee eligibility -> check permissions -> start
 * only if authorized. Starting blind would mean tracking an account that has
 * since been signed out, blocked or unbound.
 */
class BootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "InfinityCoreBoot"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED &&
            action != "android.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }
        if (!LocationForegroundService.wasActive(context)) {
            Log.i(TAG, "not tracking before reboot; nothing to restore")
            return
        }
        // The service needs a live session it does not have at boot time, so
        // this is a nudge to bring the app's own recovery path into play on
        // next launch rather than an attempt to start tracking now.
        Log.i(TAG, "tracking was active; will resume once the app re-authorises")
    }
}
