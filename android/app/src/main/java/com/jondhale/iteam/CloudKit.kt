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
        val http: OkHttpClient = OkHttpClient.Builder().connectTimeout(12, TimeUnit.SECONDS).readTimeout(60, TimeUnit.SECONDS)
            .writeTimeout(120, TimeUnit.SECONDS).retryOnConnectionFailure(true).build()
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

    fun lookup(names: List<String>, keys: List<String>? = null): Map<String, JSONObject> {
        val recs = JSONArray(); names.forEach { recs.put(JSONObject().put("recordName", it)) }
        val req = JSONObject().put("records", recs)
        if (keys != null) req.put("desiredKeys", JSONArray(keys))
        val o = call("records/lookup", req)
        val out = mutableMapOf<String, JSONObject>()
        (o.optJSONArray("records") ?: JSONArray()).forEachObj { r -> if (!r.has("serverErrorCode")) out[r.getString("recordName")] = r }
        return out
    }

    data class Profile(val userID: String, val name: String, val pubkey: String, val qr: String, val pic: String = "")

    fun profile(userID: String): Profile? {
        val r = lookup(listOf("P$userID"))["P$userID"] ?: return null
        val f = r.getJSONObject("fields")
        fun s(k: String) = f.optJSONObject(k)?.optString("value") ?: ""
        if (s("pubkey").isEmpty()) return null
        return Profile(userID, s("name"), s("pubkey"), s("qr"), s("pic"))
    }

    fun saveProfile(userID: String, name: String, pubkey: String, replace: Boolean, pic: ByteArray? = null, clearPic: Boolean = false) {
        val fields = JSONObject().put("name", v(name))
        if (pic != null) fields.put("pic", bytes(pic)) else if (clearPic) fields.put("pic", JSONObject().put("value", JSONObject.NULL))
        if (replace) fields.put("pubkey", v(pubkey))
        val rec = JSONObject().put("recordType", "Profile").put("recordName", "P$userID").put("fields", fields)
        modify(listOf(JSONObject().put("operationType", if (replace) "forceReplace" else "forceUpdate").put("record", rec)))
    }

    fun v(x: Any) = JSONObject().put("value", x)
    fun bytes(b: ByteArray) = JSONObject().put("value", E2E.b64(b)).put("type", "BYTES")

    fun envelope(to: String, from: String, conv: String, kind: Int, loud: Boolean, body: ByteArray, hint: String?): JSONObject {
        val f = JSONObject().put("rcpt", v(to)).put("sndr", v(from)).put("conv", v(conv)).put("kind", v(kind))
            .put("loud", v(if (loud) 1 else 0)).put("body", bytes(body))
        if (hint != null) f.put("hint", v(hint))
        val rec = JSONObject().put("recordType", "Envelope").put("recordName", "E" + java.util.UUID.randomUUID().toString().uppercase()).put("fields", f)
        return JSONObject().put("operationType", "create").put("record", rec)
    }

    fun create(type: String, name: String?, fields: JSONObject, op: String = "create"): JSONObject {
        val rec = JSONObject().put("recordType", type).put("fields", fields)
        if (name != null) rec.put("recordName", name)
        return JSONObject().put("operationType", op).put("record", rec)
    }

    fun delete(name: String): JSONObject = JSONObject().put("operationType", "forceDelete").put("record", JSONObject().put("recordName", name))

    fun modify(ops: List<JSONObject>) {
        ops.chunked(200).forEach { chunk ->
            val o = call("records/modify", JSONObject().put("operations", JSONArray(chunk)).put("atomic", false))
            (o.optJSONArray("records") ?: return@forEach).forEachObj { r ->
                if (r.has("serverErrorCode") && r.optString("serverErrorCode") != "NOT_FOUND") throw CloudError(r.optString("serverErrorCode") + " " + r.optString("reason"))
            }
        }
    }

    /** Generic query (public database). */
    fun query(type: String, filters: JSONArray, keys: List<String>? = null, sortByCreated: Boolean = false, limit: Int = 200): List<JSONObject> {
        val q = JSONObject().put("recordType", type).put("filterBy", filters)
        if (sortByCreated) q.put("sortBy", JSONArray().put(JSONObject().put("systemFieldName", "createdTimestamp").put("ascending", true)))
        val req = JSONObject().put("query", q).put("resultsLimit", limit)
        if (keys != null) req.put("desiredKeys", JSONArray(keys))
        val out = mutableListOf<JSONObject>()
        (call("records/query", req).optJSONArray("records") ?: JSONArray()).forEachObj { out += it }
        return out
    }

    fun eq(field: String, value: Any): JSONObject = JSONObject().put("fieldName", field).put("comparator", "EQUALS").put("fieldValue", v(value))
    fun createdAfter(ms: Long): JSONObject = JSONObject().put("systemFieldName", "createdTimestamp").put("comparator", "GREATER_THAN")
        .put("fieldValue", JSONObject().put("value", ms).put("type", "TIMESTAMP"))

    // MARK: Files (Blob records with an encrypted CKAsset, like the iPhone)

    /** Uploads already-encrypted bytes as Blob [name]. */
    fun uploadBlob(name: String, sealed: ByteArray) {
        val tok = call("assets/upload", JSONObject().put("tokens", JSONArray().put(
            JSONObject().put("recordType", "Blob").put("fieldName", "data").put("recordName", name))))
        val upURL = tok.getJSONArray("tokens").getJSONObject(0).getString("url")
        val req = Request.Builder().url(upURL).post(sealed.toRequestBody("application/octet-stream".toMediaType())).build()
        val single = http.newCall(req).execute().use { r ->
            if (!r.isSuccessful) throw CloudError("upload ${r.code}")
            JSONObject(r.body?.string() ?: "{}").getJSONObject("singleFile")
        }
        modify(listOf(create("Blob", name, JSONObject().put("data", JSONObject().put("value", single)), op = "forceReplace")))
    }

    /** Downloads the encrypted bytes of Blob [name]. */
    fun downloadBlob(name: String): ByteArray {
        val rec = lookup(listOf(name))[name] ?: throw CloudError("File not found (files are kept 45 days)")
        val url = rec.getJSONObject("fields").getJSONObject("data").getJSONObject("value").getString("downloadURL").replace("\${f}", "file")
        return http.newCall(Request.Builder().url(url).build()).execute().use { r ->
            if (!r.isSuccessful) throw CloudError("download ${r.code}")
            r.body?.bytes() ?: ByteArray(0)
        }
    }

    // MARK: Mailbox

    data class Incoming(val name: String, val from: String, val creator: String, val conv: String, val kind: Int, val body: ByteArray, val created: Long)

    /** Envelopes addressed to me, newer than [sinceMs], oldest first. */
    fun inbox(me: String, sinceMs: Long): List<Incoming> {
        val out = mutableListOf<Incoming>()
        var marker: String? = null
        do {
            val q = JSONObject().put("recordType", "Envelope")
                .put("filterBy", JSONArray().put(eq("rcpt", me)).put(createdAfter(sinceMs)))
                .put("sortBy", JSONArray().put(JSONObject().put("systemFieldName", "createdTimestamp").put("ascending", true)))
            val req = JSONObject().put("query", q).put("resultsLimit", 200)
                .put("desiredKeys", JSONArray(listOf("sndr", "conv", "kind", "body")))
            if (marker != null) req.put("continuationMarker", marker)
            val o = call("records/query", req)
            (o.optJSONArray("records") ?: JSONArray()).forEachObj { r ->
                val f = r.optJSONObject("fields") ?: return@forEachObj
                val body = f.optJSONObject("body")?.optString("value") ?: return@forEachObj
                out += Incoming(r.getString("recordName"), f.getJSONObject("sndr").getString("value"),
                    r.optJSONObject("created")?.optString("userRecordName") ?: "", f.getJSONObject("conv").getString("value"),
                    f.getJSONObject("kind").getInt("value"), E2E.unb64(body), r.optJSONObject("created")?.optLong("timestamp") ?: 0)
            }
            marker = o.optString("continuationMarker").ifEmpty { null }
        } while (marker != null && out.size < 2000)
        return out
    }
}

/** Reads a field value from a CloudKit web record. */
fun JSONObject.field(k: String): Any? = optJSONObject("fields")?.optJSONObject(k)?.opt("value")
fun JSONObject.fstr(k: String): String = (field(k) as? String) ?: ""
