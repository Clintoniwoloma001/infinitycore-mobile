#!/usr/bin/env bash
# ============================================================================
# release_smoke.sh - launch smoke test for a release APK
# ============================================================================
# Regression guard for the 1.1.7+18 failure: the release APK installed but
# crashed on launch because R8 (enabled for every release build) stripped
# Room's generated WorkDatabase_Impl constructor used by WorkManager. This
# script installs an APK on a running emulator/device, launches it, waits,
# then FAILS if logcat shows a FATAL EXCEPTION / AndroidRuntime crash.
#
# USAGE
#   scripts/release_smoke.sh [path/to/app-release.apk]
#   scripts/release_smoke.sh            # auto-picks build/app/outputs/.../*.apk
#
# EXIT CODES
#   0  installed, launched, stayed alive with no crash
#   1  a pre-condition failed (no device, no apk, install failed, crash found)
# ============================================================================
set -uo pipefail

PKG="com.infinitybank.infinitycore"
APK="${1:-}"
WAIT_SECONDS="${WAIT_SECONDS:-30}"

# Resolve the APK if not passed in.
if [[ -z "$APK" ]]; then
  APK="$(ls -t build/app/outputs/flutter-apk/app-release.apk \
              build/app/outputs/apk/release/app-release.apk 2>/dev/null | head -1)"
fi

fail() { echo "SMOKE FAIL: $*" >&2; exit 1; }
log()  { echo "[smoke] $*"; }

# --- Pre-conditions --------------------------------------------------------
command -v adb >/dev/null 2>&1 || fail "adb not on PATH"
[[ -n "$APK" && -f "$APK" ]] || fail "APK not found (pass a path or build first): ${APK:-<none>}"

DEVICE_STATE="$(adb get-state 2>/dev/null || true)"
[[ "$DEVICE_STATE" == "device" ]] || fail "no device/emulator online (adb get-state: '${DEVICE_STATE:-none}')"
log "APK: $APK"
log "device: $(adb shell getprop ro.product.cpu.abi | tr -d '\r') API $(adb shell getprop ro.build.version.sdk | tr -d '\r')"

# --- Install ---------------------------------------------------------------
# A prior install signed with a different key cannot be updated in place
# (INSTALL_FAILED_UPDATE_INCOMPATIBLE). Uninstall first so a stale signing key
# from an older build never masks a real crash.
adb uninstall "$PKG" >/dev/null 2>&1 && log "removed prior install (signature reset)"
log "installing..."
adb install -r "$APK" 2>&1 | tee /tmp/release_smoke_install.log
grep -qi '^Success' /tmp/release_smoke_install.log || fail "adb install did not succeed (see /tmp/release_smoke_install.log)"

# --- Launch ----------------------------------------------------------------
adb logcat -c
LAUNCHER="$(adb shell cmd package resolve-activity -c android.intent.category.LAUNCHER "$PKG" 2>/dev/null \
            | tr -d '\r' | sed -n 's/.*name=\([^ ]*\).*/\1/p' | head -1)"
[[ -n "$LAUNCHER" ]] || LAUNCHER="$PKG.MainActivity"
log "launching $PKG/$LAUNCHER"
adb shell am start -W -n "$PKG/$LAUNCHER" >/dev/null 2>&1 || fail "am start failed"

# --- Wait and watch --------------------------------------------------------
log "waiting ${WAIT_SECONDS}s for a crash..."
sleep "$WAIT_SECONDS"

PID="$(adb shell pidof "$PKG" 2>/dev/null | tr -d '\r')"
if [[ -z "$PID" ]]; then
  log "process not running; dumping crash context:"
  adb logcat -d | grep -iE 'FATAL|AndroidRuntime|Shorebird' | tail -40
  fail "app process $PKG is not alive after ${WAIT_SECONDS}s (it crashed or was killed)"
fi
log "process alive, pid=$PID"

# --- Crash detection -------------------------------------------------------
if adb logcat -d | grep -qiE 'FATAL EXCEPTION|AndroidRuntime: java\.lang|E AndroidRuntime'; then
  log "CRASH DETECTED in logcat:"
  adb logcat -d | grep -iE 'FATAL EXCEPTION|AndroidRuntime|Shorebird|tracking_unavailable' | tail -60
  fail "logcat contains a FATAL EXCEPTION / AndroidRuntime crash"
fi

log "SMOKE PASS: installed, launched, alive ${WAIT_SECONDS}s, no crash"
exit 0
