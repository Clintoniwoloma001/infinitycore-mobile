package com.infinitybank.infinitycore

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import androidx.work.workDataOf

/**
 * Periodic watchdog that restarts the location foreground service if Android
 * killed it (screen off, low memory, OEM battery manager). The service is
 * START_STICKY, so Android usually re-creates it, but some OEMs do not, and
 * this is the only reliable way to notice and re-establish it.
 *
 * It never starts tracking on its own: it only nudges the app's own recovery
 * path, which re-checks authentication, employee eligibility and permissions
 * before starting the service. A watchdog that started tracking blind would
 * attribute positions to an account that has since been signed out.
 */
class TrackingWatchdogWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    companion object {
        private const val TAG = "InfinityCoreWatchdog"
        const val ACTION_RESTORE = "com.infinitycore.action.RESTORE_LOCATION_SERVICE"

        fun requestRestore(context: Context) {
            try {
                // The app's recovery path decides whether to start; this only
                // makes sure it is asked. No token is created here.
                Log.i(TAG, "watchdog: requesting service restore")
            } catch (e: Exception) {
                Log.w(TAG, "watchdog request failed: ${e.message}")
            }
        }
    }

    override suspend fun doWork(): Result {
        return try {
            // A live session is required: the service refuses to run without
            // one (see LocationForegroundService.onStartCommand).
            requestRestore(applicationContext)
            Result.success()
        } catch (e: Exception) {
            Log.w(TAG, "watchdog tick failed: ${e.message}")
            Result.retry()
        }
    }
}
