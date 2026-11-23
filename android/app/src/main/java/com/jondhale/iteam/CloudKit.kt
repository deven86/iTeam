package com.jondhale.iteam

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

class AuthNeeded(val redirectURL: String) : Exception("Sign in with your Apple ID")
class CloudError(msg: String) : Exception(msg)

/** CloudKit Web Services for the iPhone app's public database — the same encrypted mailbox, no server of ours. */
class CloudKit(private val store: Store) {
    companion object {
        val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(12, TimeUnit.SECONDS).readTimeout(30, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true).build()
    }
    private val base = "https://api.apple-cloudkit.com/database/1/iCloud.com.jondhale.iteam/${BuildConfig.CK_ENV}/public"
    private val json = "application/json".toMediaType()

    val configured get() = BuildConfig.CK_TOKEN.isNotEmpty()

    private fun url(path: String): String {
        var u = "$base/$path?ckAPIToken=${URLEncoder.encode(BuildConfig.CK_TOKEN, "UTF-8")}"
        val t = store.webToken
        if (t.isNotEmpty()) u += "&ckWebAuthToken=" + URLEncoder.encode(t, "UTF-8")
        return u
    }

    private fun call(path: String, body: JSONObject?): JSONObject {
        val b = Request.Builder().url(url(path))
        if (body != null) b.post(body.toString().toRequestBody(json)) else b.get()
        http.newCall(b.build()).execute().use { r ->
            val text = r.body?.string() ?: ""
            val o = runCatching { JSONObject(text) }.getOrElse { JSONObject() }
            if (o.has("ckWebAuthToken")) store.webToken = o.getString("ckWebAuthToken")
            if (r.code == 421 || o.optString("serverErrorCode") == "AUTHENTICATION_REQUIRED") {
                store.webToken = ""
                throw AuthNeeded(o.optString("redirectURL"))
            }
            if (!r.isSuccessful) throw CloudError("${r.code} ${o.optString("serverErrorCode")} ${o.optString("reason")}")
            return o
        }
    }

    /** My iCloud user record name — the same ID the iPhone app uses for this Apple ID. */
    fun me(): String = call("users/caller", null).getString("userRecordName")

    fun lookup(names: List<String>): Map<String, JSONObject> {
        val recs = JSONArray(); names.forEach { recs.put(JSONObject().put("recordName", it)) }
        val o = call("records/lookup", JSONObject().put("records", recs))
        val out = mutableMapOf<String, JSONObject>()
        val arr = o.optJSONArray("records") ?: JSONArray()
        for (i in 0 until arr.length()) {
            val r = arr.getJSONObject(i)
            if (!r.has("serverErrorCode")) out[r.getString("recordName")] = r
        }
        return out
    }

    data class Profile(val userID: String, val name: String, val pubkey: String, val qr: String)

    fun profile(userID: String): Profile? {
        val r = lookup(listOf("P$userID"))["P$userID"] ?: return null
        val f = r.getJSONObject("fields")
        fun s(k: String) = f.optJSONObject(k)?.optString("value") ?: ""
        if (s("pubkey").isEmpty()) return null
        return Profile(userID, s("name"), s("pubkey"), s("qr"))
    }

    fun saveProfile(userID: String, name: String, pubkey: String, replace: Boolean) {
        val fields = JSONObject().put("name", v(name))
        if (replace) fields.put("pubkey", v(pubkey))
        val rec = JSONObject().put("recordType", "Profile").put("recordName", "P$userID").put("fields", fields)
        modify(listOf(JSONObject().put("operationType", if (replace) "forceReplace" else "forceUpdate").put("record", rec)))
    }

    private fun v(x: Any) = JSONObject().put("value", x)

    fun envelope(to: String, from: String, conv: String, kind: Int, loud: Boolean, body: ByteArray, hint: String?): JSONObject {
        val f = JSONObject().put("rcpt", v(to)).put("sndr", v(from)).put("conv", v(conv)).put("kind", v(kind))
            .put("loud", v(if (loud) 1 else 0)).put("body", v(E2E.b64(body)))
        if (hint != null) f.put("hint", v(hint))
        val rec = JSONObject().put("recordType", "Envelope").put("recordName", "E" + java.util.UUID.randomUUID().toString().uppercase()).put("fields", f)
        return JSONObject().put("operationType", "create").put("record", rec)
    }

    fun modify(ops: List<JSONObject>) {
        ops.chunked(200).forEach { chunk ->
            val o = call("records/modify", JSONObject().put("operations", JSONArray(chunk)).put("atomic", false))
            val arr = o.optJSONArray("records") ?: return@forEach
            for (i in 0 until arr.length()) {
                val r = arr.getJSONObject(i)
                if (r.has("serverErrorCode")) throw CloudError(r.optString("serverErrorCode") + " " + r.optString("reason"))
            }
        }
    }

    data class Incoming(val name: String, val from: String, val creator: String, val conv: String, val kind: Int, val body: ByteArray, val created: Long)

    /** Envelopes addressed to me, newer than [sinceMs], oldest first. */
    fun inbox(me: String, sinceMs: Long): List<Incoming> {
        val out = mutableListOf<Incoming>()
        var marker: String? = null
        do {
            val q = JSONObject().put("recordType", "Envelope")
                .put("filterBy", JSONArray()
                    .put(JSONObject().put("fieldName", "rcpt").put("comparator", "EQUALS").put("fieldValue", v(me)))
                    .put(JSONObject().put("systemFieldName", "createdTimestamp").put("comparator", "GREATER_THAN")
                        .put("fieldValue", JSONObject().put("value", sinceMs).put("type", "TIMESTAMP"))))
                .put("sortBy", JSONArray().put(JSONObject().put("systemFieldName", "createdTimestamp").put("ascending", true)))
            val req = JSONObject().put("query", q).put("resultsLimit", 200)
                .put("desiredKeys", JSONArray(listOf("sndr", "conv", "kind", "body")))
            if (marker != null) req.put("continuationMarker", marker)
            val o = call("records/query", req)
            val arr = o.optJSONArray("records") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val r = arr.getJSONObject(i)
                val f = r.optJSONObject("fields") ?: continue
                val body = f.optJSONObject("body")?.optString("value") ?: continue
                out += Incoming(r.getString("recordName"), f.getJSONObject("sndr").getString("value"),
                    r.optJSONObject("created")?.optString("userRecordName") ?: "", f.getJSONObject("conv").getString("value"),
                    f.getJSONObject("kind").getInt("value"), E2E.unb64(body), r.optJSONObject("created")?.optLong("timestamp") ?: 0)
            }
            marker = o.optString("continuationMarker").ifEmpty { null }
        } while (marker != null && out.size < 2000)
        return out
    }
}
