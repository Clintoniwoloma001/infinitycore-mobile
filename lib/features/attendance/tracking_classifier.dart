/// Employee Tracking bucket classification — mobile.
///
/// Must match web SARA Live positions logic. Do not widen the 48 h window or
/// bypass this classifier.
///
/// The web groups the rows returned by `employee_live_positions_v4` by the
/// server's own `display_category` field and NEVER recomputes a verdict, so
/// this classifier does the same: it reads the server's category and the
/// server-computed age, and only falls back to deriving a bucket when a row
/// predates that field. The precedence is the web's:
///
///   1. no fix within the last 48 h            -> not listed at all
///   2. no geofence configured for the branch   -> NoGeofence
///   3. a fix older than 30 minutes (stale)     -> Stale  (overrides the verdict)
///   4. the server's inside/outside verdict     -> Inside / Outside
///
/// The staleness check deliberately comes BEFORE the server's category: the
/// server is consistent by construction (it only ever emits 'inside'/'outside'
/// for a fix inside the freshness window), and if a row ever disagreed, the age
/// is the safe authority — a two-day-old fix must never read as a current
/// verdict. That is why the sum invariant (inside + outside + stale +
/// unconfigured === rows listed) holds on real data and still holds here.
///
/// Every inside/outside verdict comes from the server geofence engine; this
/// file never computes a distance or decides that a point is inside a fence.
library;

/// How long a fix keeps an employee on the Live positions tab. Matches the
/// web's `RECENT_HOURS` and the RPC's `recorded_at >= now() - interval`.
const int trackingRecentHours = 48;

/// A fix older than this is STALE: it gets the grey bucket and "Last known …"
/// wording, never a bright Inside badge. Matches the web's
/// `FRESHNESS_SECONDS.DELAYED` (6 min live / 30 min delayed).
const int trackingStaleMinutes = 30;

/// The four mutually exclusive buckets, in the web's display order.
/// Exactly one applies to every listed row, so the counts sum to the total.
enum TrackingBucket { inside, outside, stale, noGeofence }

/// Classifies one `employee_live_positions_v4` row.
///
/// Returns null when the employee must not be listed at all — no fix inside
/// the [trackingRecentHours] window. The age is anchored to the SERVER clock:
/// the row's `age_seconds` is computed in Postgres, so a wrong device clock can
/// never turn a two-day-old fix into a current one. `now` is only used to bound
/// the window (and to age a row that carries `recorded_at` instead).
TrackingBucket? classifyTrackingEntry(
  Map<String, dynamic> entry, {
  required DateTime now,
  int recentHours = trackingRecentHours,
}) {
  final age = _ageSeconds(entry, now: now);
  if (age == null) return null; // no fix at all -> never listed
  if (age > recentHours * 3600) return null; // outside the 48 h window

  final category = '${entry['display_category'] ?? ''}'.toLowerCase();

  // No fence: the branch has no geofence, so there is no verdict to show.
  if (category == 'unconfigured' || _isUnconfigured(entry)) {
    return TrackingBucket.noGeofence;
  }

  // Stale overrides the verdict: an old fix is never a current one.
  if (age > trackingStaleMinutes * 60 || category == 'stale') {
    return TrackingBucket.stale;
  }

  // The server's own category is the primary answer; the derived flags are
  // only for rows from an older RPC shape that carries no category.
  if (category == 'inside' || _isInside(entry)) return TrackingBucket.inside;
  if (category == 'outside' || _isOutside(entry)) return TrackingBucket.outside;

  // The server answered neither way: bucketing it as a verdict would invent
  // one, so it stays with the stale set (never presented as current).
  return TrackingBucket.stale;
}

/// Counts per bucket for a set of already-classified entries.
///
/// Counting happens from the SAME rows that are rendered, so the header can
/// neither drift from the list nor overlap itself.
Map<TrackingBucket, int> countTrackingBuckets(
  Iterable<TrackingBucket?> buckets,
) {
  final counts = <TrackingBucket, int>{
    for (final b in TrackingBucket.values) b: 0,
  };
  for (final b in buckets) {
    if (b != null) counts[b] = counts[b]! + 1;
  }
  return counts;
}

/// The rows a caller may list: classified, in the bucket order, newest first.
List<Map<String, dynamic>> classifyTrackingRows(
  Iterable<Map<String, dynamic>> rows, {
  required DateTime now,
  int recentHours = trackingRecentHours,
}) {
  final out = <Map<String, dynamic>>[];
  for (final row in rows) {
    if (classifyTrackingEntry(row, now: now, recentHours: recentHours) !=
        null) {
      out.add(row);
    }
  }
  return out;
}

/// Whether a fix is old enough to read as stale (matches the web's 30-minute
/// DELAYED boundary: at or under it the verdict still shows).
bool isTrackingStale(Map<String, dynamic> entry, {required DateTime now}) {
  final age = _ageSeconds(entry, now: now);
  if (age == null) return false;
  return age > trackingStaleMinutes * 60;
}

/// The web's "delayed" hint: fresh enough to still show a verdict, but older
/// than 6 minutes.
bool isTrackingDelayed(Map<String, dynamic> entry, {required DateTime now}) {
  final age = _ageSeconds(entry, now: now);
  if (age == null) return false;
  return age > 6 * 60 && age <= trackingStaleMinutes * 60;
}

/// A fix whose GPS error exceeds the fence radius cannot prove inside/outside,
/// so the web marks it "(low GPS accuracy)". Kept so the same warning shows on
/// mobile; the verdict itself still comes from the server.
bool isLowAccuracyFix(Map<String, dynamic> entry) {
  final accuracy = _num(entry['accuracy_m'] ?? entry['accuracy']);
  final radius = _num(entry['radius_m'] ?? entry['fence_radius_m']);
  if (accuracy == null || radius == null || radius <= 0) return false;
  return accuracy > radius;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// Age of the fix in seconds, anchored to the server clock. `age_seconds` is
/// computed by Postgres (`now() - recorded_at`), so it is preferred; the
/// elapsed wall-clock since the response arrived is added by the caller, not
/// here, so a wrong device clock cannot invent an age.
int? _ageSeconds(Map<String, dynamic> entry, {required DateTime now}) {
  final serverAge = _num(entry['age_seconds']);
  if (serverAge != null && serverAge >= 0) return serverAge.round();

  final recordedAt = DateTime.tryParse('${entry['recorded_at'] ?? ''}');
  if (recordedAt != null) {
    return now.difference(recordedAt.toUtc()).inSeconds;
  }

  final minutesAgo = _num(entry['minutes_ago']);
  if (minutesAgo != null && minutesAgo >= 0) return (minutesAgo * 60).round();
  return null;
}

bool _isUnconfigured(Map<String, dynamic> entry) {
  final status = '${entry['geofence_status'] ?? ''}'.toLowerCase();
  if (status == 'unconfigured') return true;
  // A row that carries no fence answer at all (no geofence_id and no
  // registered name) is the "no geofence set for this branch" case. A row that
  // says inside or outside obviously has one.
  if (status == 'inside' || status == 'outside') return false;
  final hasFence = _text(entry['geofence_id']) != null ||
      _text(entry['geofence_name']) != null;
  return !hasFence;
}

bool _isInside(Map<String, dynamic> entry) {
  if (entry['inside_geofence'] == true) return true;
  final status = '${entry['geofence_status'] ?? ''}'.toLowerCase();
  return status == 'inside';
}

bool _isOutside(Map<String, dynamic> entry) {
  if (entry['inside_geofence'] == false) return true;
  final status = '${entry['geofence_status'] ?? ''}'.toLowerCase();
  return status == 'outside';
}

num? _num(dynamic v) {
  if (v is num) return v;
  final parsed = num.tryParse('${v ?? ''}');
  return parsed;
}

String? _text(dynamic v) {
  if (v == null) return null;
  final t = v.toString().trim();
  if (t.isEmpty || t.toLowerCase() == 'null') return null;
  return t;
}
