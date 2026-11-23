package com.jondhale.iteam

import android.annotation.SuppressLint
import android.content.Context
import android.location.Location
import android.location.LocationManager
import android.os.Build
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONArray
import org.json.JSONObject
import kotlin.coroutines.resume

/** Nearby search — the same opt-in "Nearby" records as the iPhone: name, one line, category and a position
 *  rounded to about 1 km, for a limited time. */
class Nearby(private val store: Store, private val cloud: CloudKit) {
    data class Listing(val id: String, val name: String, val kind: String, val category: String, val about: String, val km: Double)

    companion object {
        val categories = listOf("Shop / store", "Restaurant / food", "Doctor / clinic", "Lawyer / advocate", "Builder / contractor", "Gym / trainer",
            "Tutor / classes", "Plumber / electrician", "Salon / beauty", "Society / apartment", "Office / company", "Other")

        @SuppressLint("MissingPermission")
        suspend fun locate(ctx: Context): Location? {
            val lm = ctx.getSystemService(LocationManager::class.java)
            val provider = listOf(LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER).firstOrNull { runCatching { lm.isProviderEnabled(it) }.getOrDefault(false) }
                ?: return null
            lm.getLastKnownLocation(provider)?.takeIf { System.currentTimeMillis() - it.time < 10 * 60_000 }?.let { return it }
            return withTimeoutOrNull(15_000) {
                suspendCancellableCoroutine { c ->
                    if (Build.VERSION.SDK_INT >= 30) lm.getCurrentLocation(provider, null, ctx.mainExecutor) { c.resume(it) }
                    else @Suppress("DEPRECATION") lm.requestSingleUpdate(provider, { c.resume(it) }, ctx.mainLooper)
                }
            }
        }
    }

    var until: Long
        get() = store.secret("nearby.until")?.toLongOrNull()?.takeIf { it > System.currentTimeMillis() } ?: 0
        set(v) = store.setSecret("nearby.until", v.toString())

    fun publish(loc: Location, name: String, kind: String, category: String, about: String, hours: Int) {
        val lat = Math.round(loc.latitude * 100) / 100.0; val lon = Math.round(loc.longitude * 100) / 100.0
        val end = System.currentTimeMillis() + hours * 3_600_000L
        val f = JSONObject().put("uid", cloud.v(store.me)).put("name", cloud.v(name.take(60))).put("kind", cloud.v(kind)).put("cat", cloud.v(category))
            .put("about", cloud.v(about.take(160))).put("pubkey", cloud.v(store.myPublicKey))
            .put("cell", cloud.v(Geohash.encode(loc.latitude, loc.longitude, 5))).put("lat", cloud.v(lat)).put("lon", cloud.v(lon))
            .put("until", JSONObject().put("value", end).put("type", "TIMESTAMP"))
        cloud.modify(listOf(cloud.create("Nearby", "N" + store.me, f, op = "forceReplace")))
        until = end
    }

    fun remove() { runCatching { cloud.modify(listOf(cloud.delete("N" + store.me))) }; until = 0 }

    fun search(loc: Location, radiusKm: Double): List<Listing> {
        val cells = Geohash.neighbours(Geohash.encode(loc.latitude, loc.longitude, 5))
        val filters = JSONArray()
            .put(JSONObject().put("fieldName", "cell").put("comparator", "IN").put("fieldValue", JSONObject().put("value", JSONArray(cells)).put("type", "STRING_LIST")))
            .put(JSONObject().put("fieldName", "until").put("comparator", "GREATER_THAN").put("fieldValue", JSONObject().put("value", System.currentTimeMillis()).put("type", "TIMESTAMP")))
        val blocked = emptySet<String>()
        return cloud.query("Nearby", filters, listOf("uid", "name", "kind", "cat", "about", "lat", "lon")).mapNotNull { r ->
            val uid = r.fstr("uid"); if (uid.isEmpty() || uid == store.me || uid in blocked) return@mapNotNull null
            val lat = (r.field("lat") as? Number)?.toDouble() ?: return@mapNotNull null
            val lon = (r.field("lon") as? Number)?.toDouble() ?: return@mapNotNull null
            val d = FloatArray(1); Location.distanceBetween(loc.latitude, loc.longitude, lat, lon, d)
            val km = d[0] / 1000.0
            if (km > radiusKm) null else Listing(uid, r.fstr("name"), r.fstr("kind").ifEmpty { "person" }, r.fstr("cat"), r.fstr("about"), km)
        }.sortedBy { it.km }
    }
}

/** Base-32 geohash, identical to the iPhone's. */
object Geohash {
    private const val CH = "0123456789bcdefghjkmnpqrstuvwxyz"

    fun encode(lat: Double, lon: Double, length: Int): String {
        var la0 = -90.0; var la1 = 90.0; var lo0 = -180.0; var lo1 = 180.0
        val out = StringBuilder(); var bit = 0; var ch = 0; var even = true
        while (out.length < length) {
            if (even) { val m = (lo0 + lo1) / 2; if (lon >= m) { ch = ch or (1 shl (4 - bit)); lo0 = m } else lo1 = m }
            else { val m = (la0 + la1) / 2; if (lat >= m) { ch = ch or (1 shl (4 - bit)); la0 = m } else la1 = m }
            even = !even
            if (bit < 4) bit++ else { out.append(CH[ch]); bit = 0; ch = 0 }
        }
        return out.toString()
    }

    private fun decode(h: String): DoubleArray {
        var la0 = -90.0; var la1 = 90.0; var lo0 = -180.0; var lo1 = 180.0; var even = true
        for (c in h) {
            val v = CH.indexOf(c); if (v < 0) continue
            for (b in 4 downTo 0) {
                val on = (v shr b) and 1 == 1
                if (even) { val m = (lo0 + lo1) / 2; if (on) lo0 = m else lo1 = m } else { val m = (la0 + la1) / 2; if (on) la0 = m else la1 = m }
                even = !even
            }
        }
        return doubleArrayOf((la0 + la1) / 2, (lo0 + lo1) / 2, la1 - la0, lo1 - lo0)
    }

    fun neighbours(h: String): List<String> {
        val c = decode(h); val out = mutableListOf<String>()
        for (dy in -1..1) for (dx in -1..1) {
            val lat = (c[0] + dy * c[2]).coerceIn(-89.99, 89.99)
            var lon = c[1] + dx * c[3]; if (lon > 180) lon -= 360; if (lon < -180) lon += 360
            val n = encode(lat, lon, h.length); if (n !in out) out += n
        }
        return out
    }
}
