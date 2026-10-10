package com.infinitybank.infinitycore

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.nio.charset.StandardCharsets
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import android.database.sqlite.SQLiteDatabase

/**
 * Foreground service that keeps recording work-location fixes while the app is
 * backgrounded or otherwise not on screen.
 *
 * WHY NATIVE INSTEAD OF THE DART TIMER
 * The Dart heartbeat lives on the UI isolate, which Android suspends and then
 * kills. A foreground service is the only supported mechanism allowed to keep
 * working in the background, so the capture loop lives here.
 *
 * HONEST LIMITS (deliberately not worked around)
 * Android can still stop this service: a user force-stop, an OEM battery
 * manager, or revoked permissions. There is no "cannot be killed" guarantee and
 * none is claimed. The service restarts itself while the OS allows it, and
 * [BootReceiver] re-establishes it after a reboot. Force-stop is respected: it
 * is never bypassed or worked around.
 *
 * SECURITY
 * The Supabase access token is handed in by Dart at start time and held in
 * memory only. It is never written to disk by this class and never logged. If
 * the process is restarted by the system and no token was supplied, the service
 * stops itself rather than recording positions that could not be attributed to
 * an account - unattributed location data is worse than none.
 */
class LocationForegroundService : Service(), LocationListener {

    companion object {
        private const val TAG = "InfinityCoreLocation"
        private const val CHANNEL_ID = "infinitycore_location_service"
        private const val NOTIFICATION_ID = 4711

        const val ACTION_START = "com.infinitycore.action.START_LOCATION"
        const val ACTION_STOP = "com.infinitycore.action.STOP_LOCATION"

        const val EXTRA_ACCESS_TOKEN = "access_token"
        const val EXTRA_SUPABASE_URL = "supabase_url"
        const val EXTRA_RPC_PATH = "rpc_path"
        const val EXTRA_ANON_KEY = "anon_key"

        /** Prefs flag recording that the user was tracking before a reboot. */
        const val PREFS = "infinitycore_location_prefs"
        const val KEY_WAS_ACTIVE = "was_active"

        // TIME-BASED cadence: one fix every 120 s whether or not the person has
        // moved. The old minDistance=10 m gate suppressed fixes while a
        // stationary employee was at a desk, which is exactly when an admin
        // needs to know the person is still at the office. Distance is now 0.
        // Interval is capped at 120 s per the tracking policy.
        private const val MIN_INTERVAL_MS = 2L * 60L * 1000L
        private const val MIN_DISTANCE_M = 0f

        fun start(context: Context, token: String, supabaseUrl: String,
                rpcPath: String, anonKey: String) {
            val intent = Intent(context, LocationForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_ACCESS_TOKEN, token)
                putExtra(EXTRA_SUPABASE_URL, supabaseUrl)
                putExtra(EXTRA_RPC_PATH, rpcPath)
                putExtra(EXTRA_ANON_KEY, anonKey)
            }
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit().putBoolean(KEY_WAS_ACTIVE, false).apply()
            context.stopService(Intent(context, LocationForegroundService::class.java))
        }

        fun wasActive(context: Context): Boolean =
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_WAS_ACTIVE, false)
    }

    private var accessToken: String? = null
    private var supabaseUrl: String? = null
    private var rpcPath: String? = null

    // Supabase `apikey` PROJECT key (NOT the user JWT). Required by the REST
    // gateway on every call; native previously reused the user token here and
    // every direct upload was rejected with HTTP 401 on real devices.
    private var anonKey: String? = null
    private var locationManager: LocationManager? = null
    private val io = Executors.newSingleThreadExecutor()
    private val uploading = AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                accessToken = intent?.getStringExtra(EXTRA_ACCESS_TOKEN)
                supabaseUrl = intent?.getStringExtra(EXTRA_SUPABASE_URL)
                rpcPath = intent?.getStringExtra(EXTRA_RPC_PATH)
                anonKey = intent?.getStringExtra(EXTRA_ANON_KEY)
            }
        }

        // No usable session: do not pretend to track.
        if (accessToken.isNullOrBlank() || supabaseUrl.isNullOrBlank()) {
            Log.w(TAG, "start requested without a session; stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_WAS_ACTIVE, true).apply()

        // PERMISSION FIRST, FOREGROUND SECOND.
        // On Android 14+ (API 34) calling startForeground() with
        // FOREGROUND_SERVICE_TYPE_LOCATION while the app does NOT hold the
        // runtime location grant throws a SecurityException and crashes the
        // process. So we must confirm the grant BEFORE entering the foreground,
        // never after. When it is missing we log tracking_unavailable, stop
        // cleanly, and let the app re-prompt on next launch - we do NOT crash.
        if (!hasPermission()) {
            Log.w(TAG, "tracking_unavailable: location permission not granted")
            stopSelf()
            return START_NOT_STICKY
        }

        createChannel()
        startForegroundCompat()

        if (!beginLocationUpdates()) {
            Log.w(TAG, "cannot start updates (permission or provider); stopping")
            stopSelf()
            return START_NOT_STICKY
        }

        // Survive a low-memory kill for as long as Android permits it.
        return START_STICKY
    }

    private fun startForegroundCompat() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            // No employee name, no position, nothing sensitive: this is visible
            // on a lock screen and in the shade.
            .setContentTitle("InfinityCore attendance service active")
            .setContentText("Recording work-location for attendance")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID, "Attendance location service", NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Shown while InfinityCore records work-location for attendance."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED ||
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    private fun beginLocationUpdates(): Boolean {
        if (!hasPermission()) return false
        val manager = getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return false
        val usable = listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
            .filter { manager.isProviderEnabled(it) }
        if (usable.isEmpty()) {
            Log.w(TAG, "no location provider enabled")
            return false
        }
        locationManager = manager
        return try {
            usable.forEach { provider ->
                manager.requestLocationUpdates(
                    provider, MIN_INTERVAL_MS, MIN_DISTANCE_M, this
                )
            }
            true
        } catch (se: SecurityException) {
            Log.e(TAG, "missing permission for location updates", se)
            false
        }
    }

    override fun onLocationChanged(location: Location) {
        if (!uploading.compareAndSet(false, true)) return
        io.execute {
            try {
                upload(location)
            } catch (e: Exception) {
                Log.w(TAG, "upload failed: ${e.message}")
            } finally {
                uploading.set(false)
            }
        }
    }

    @Deprecated("Required by LocationListener on API < 29")
    override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) = Unit

    override fun onProviderEnabled(provider: String) = Unit

    override fun onProviderDisabled(provider: String) {
        // Location was switched off. Say so instead of silently going quiet.
        Log.w(TAG, "provider disabled: $provider")
    }

    /**
     * Posts one fix to the same server RPC the Dart heartbeat uses, so both
     * paths land in the same place with the same semantics.
     */

    // OFFLINE QUEUE: write EVERY fix to SQLite first, then attempt upload.
    // This matches the Dart-side queue (offline_location_queue.db, same schema).
    private fun enqueueToSqlite(location: Location, accuracy: Float?, battery: Float?, networkStatus: String?) {
        try {
            // Invariant 4c: a physically impossible coordinate must never reach
            // the queue - it would be indistinguishable from a real position.
            val lat = location.latitude
            val lng = location.longitude
            if (lat.isNaN() || lng.isNaN() || lat < -90.0 || lat > 90.0 || lng < -180.0 || lng > 180.0) {
                Log.w(TAG, "invalid coordinate dropped: ($lat, $lng)")
                return
            }
            val dbPath = getDatabasePath("offline_location_queue.db")
            val conn = SQLiteDatabase.openOrCreateDatabase(dbPath.absolutePath, null)
            // Invariant 4a: WAL + a busy timeout so the Dart heartbeat (which
            // opens the SAME file) and this service can both write without one
            // side failing with SQLITE_BUSY and dropping a fix.
            conn.execSQL("PRAGMA journal_mode = WAL")
            conn.execSQL("PRAGMA busy_timeout = 5000")
            // The schema MUST match the Dart queue exactly. `state` defaults to
            // 'ok' and Dart's flush only selects state='ok' rows; without the
            // column every native-queued row would be silently skipped on
            // upload (a device that captured offline via the service would show
            // zero rows arriving). IF NOT EXISTS keeps this safe on upgrade.
            conn.execSQL("CREATE TABLE IF NOT EXISTS offline_location_queue (id INTEGER PRIMARY KEY AUTOINCREMENT, employee_id TEXT, latitude REAL, longitude REAL, accuracy REAL, battery_level REAL, network_status TEXT, recorded_at TEXT NOT NULL, is_synced INTEGER DEFAULT 0, attempts INTEGER DEFAULT 0, state TEXT DEFAULT 'ok')")
            conn.execSQL("CREATE INDEX IF NOT EXISTS idx_offline_unsynced ON offline_location_queue(is_synced, recorded_at ASC)")
            val nowIso = java.time.Instant.ofEpochMilli(System.currentTimeMillis())
                .atZone(java.time.ZoneOffset.UTC).format(java.time.format.DateTimeFormatter.ISO_OFFSET_DATE_TIME)
            // NEVER persist the access token to disk: the SECURITY contract of
            // this class forbids it, and the server attributes queued rows
            // from the session (auth.uid()) when Dart flushes them, so the
            // column only needs a non-null placeholder here.
            val stmt = conn.compileStatement(
                "INSERT INTO offline_location_queue (employee_id, latitude, longitude, accuracy, battery_level, network_status, recorded_at, is_synced, attempts, state) VALUES (?,?,?,?,?,?,?,?,?,?)"
            )
            // NEVER persist the access token to disk: the SECURITY contract above
            // forbids it, and the server attributes rows from the session anyway
            // (auth.uid()), so the column only needs a non-null placeholder here.
            stmt.bindString(1, "")
            stmt.bindDouble(2, lat)
            stmt.bindDouble(3, lng)
            stmt.bindDouble(4, accuracy?.toDouble() ?: 0.0)
            stmt.bindDouble(5, battery?.toDouble() ?: 0.0)
            stmt.bindString(6, networkStatus ?: "unknown")
            stmt.bindString(7, nowIso)
            stmt.bindLong(8, 0)  // is_synced = 0
            stmt.bindLong(9, 0)  // attempts = 0
            stmt.bindString(10, "ok")  // state = 'ok' so Dart's flush picks it up
            stmt.executeInsert()
            stmt.close()
            conn.close()
        } catch (e: Exception) {
            Log.w(TAG, "offline queue sqlite insert failed: ${e.message}")
        }
    }

    private fun upload(location: Location) {
        val token = accessToken ?: return
        val base = supabaseUrl ?: return
        val path = rpcPath ?: "/rest/v1/rpc/record_employee_location"

        // A fix older than 5 minutes would misrepresent where the person is.
        val ageMs = System.currentTimeMillis() - location.time
        if (ageMs > 5L * 60L * 1000L) {
            Log.w(TAG, "stale fix (${ageMs}ms) discarded")
            return
        }

        val recordedAt = OffsetDateTime.ofInstant(
            java.time.Instant.ofEpochMilli(location.time),
            java.time.ZoneId.systemDefault()
        ).format(DateTimeFormatter.ISO_OFFSET_DATE_TIME)

        val accuracy =
            if (location.hasAccuracy()) location.accuracy.toDouble().toString() else "null"
        val body = "{\"p_lat\":${location.latitude},\"p_lng\":${location.longitude}," +
            "\"p_accuracy\":$accuracy,\"p_recorded_at\":\"$recordedAt\"," +
            "\"p_source\":\"mobile\",\"p_source_detail\":\"foreground_service\"}"

        // Queue first (even if upload fails).
        enqueueToSqlite(location, if (location.hasAccuracy()) location.accuracy else null,
            null, null)  // battery/network: best effort; add BatteryManager if needed
        val conn = URL(base.trimEnd('/') + path).openConnection() as HttpURLConnection
        try {
            conn.requestMethod = "POST"
            conn.doOutput = true
            conn.connectTimeout = 20_000
            conn.readTimeout = 20_000
            conn.setRequestProperty("Content-Type", "application/json")
            // `apikey` is the PROJECT (anon) key; `Authorization` is the user JWT.
            // Sending the user token as the apikey is rejected with HTTP 401.
            conn.setRequestProperty("apikey", anonKey ?: "")
            conn.setRequestProperty("Authorization", "Bearer $token")
            conn.outputStream.use { it.write(body.toByteArray(StandardCharsets.UTF_8)) }
            val code = conn.responseCode
            if (code !in 200..299) {
                Log.w(TAG, "server rejected fix: HTTP $code")
            }
        } finally {
            conn.disconnect()
        }
    }

    override fun onDestroy() {
        try {
            locationManager?.removeUpdates(this)
        } catch (se: SecurityException) {
            Log.w(TAG, "could not remove updates", se)
        }
        locationManager = null
        io.shutdown()
        super.onDestroy()
    }
}
