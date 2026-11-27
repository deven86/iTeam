package com.jondhale.iteam

import android.app.Activity
import androidx.credentials.CredentialManager
import androidx.credentials.CustomCredential
import androidx.credentials.GetCredentialRequest
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

/** iTeam Next builds talk to our own relay (relay.iteamchat.in); classic builds use CloudKit. */
fun newCloud(store: Store): CloudKit = if (BuildConfig.RELAY) RelayCloud(store) else CloudKit(store)

/** Asks Google for an ID token (Sign in with Google). Must be called from an Activity. */
suspend fun googleIdToken(activity: Activity): String {
    if (BuildConfig.GOOGLE_WEB_CLIENT_ID.isEmpty()) throw CloudError("Google sign-in isn't set up in this build yet")
    val option = GetSignInWithGoogleOption.Builder(BuildConfig.GOOGLE_WEB_CLIENT_ID).build()
    val res = CredentialManager.create(activity).getCredential(activity, GetCredentialRequest.Builder().addCredentialOption(option).build())
    val c = res.credential
    if (c is CustomCredential && c.type == GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL)
        return GoogleIdTokenCredential.createFrom(c.data).idToken
    throw CloudError("Google sign-in didn't return an account")
}

/**
 * The relay mailbox, with the same calls the rest of the app already uses for CloudKit.
 * Everything that travels is already end-to-end encrypted on this phone; the relay only stores
 * it until every device of the recipient has it.
 */
class RelayCloud(private val store: Store) : CloudKit(store) {
    private val base = BuildConfig.RELAY_URL.trimEnd('/')
    private val json = "application/json".toMediaType()

    override val configured get() = base.isNotEmpty()

    private var deviceID: String
        get() = store.secret("relay.device") ?: newID().also { store.setSecret("relay.device", it) }
        set(v) { store.setSecret("relay.device", v) }
    private var seq: Long
        get() = store.secret("relay.seq")?.toLongOrNull() ?: 0
        set(v) { store.setSecret("relay.seq", v.toString()) }
    private var acked: Long
        get() = store.secret("relay.acked")?.toLongOrNull() ?: 0
        set(v) { store.setSecret("relay.acked", v.toString()) }

    /** Delete my account on the relay (and everything it holds). */
    fun deleteMe() { runCatching { call("DELETE", "v1/me") } }

    private fun call(method: String, path: String, body: Any? = null, auth: Boolean = true): JSONObject {
        val b = Request.Builder().url(base + path)
        if (auth) {
            if (store.webToken.isEmpty()) throw AuthNeeded("")
            b.header("Authorization", "Bearer " + store.webToken)
        }
        val rb = when (body) {
            null -> null
            is ByteArray -> body.toRequestBody("application/octet-stream".toMediaType())
            else -> body.toString().toRequestBody(json)
        }
        b.method(method, rb ?: if (method == "POST" || method == "PUT") "{}".toRequestBody(json) else null)
        CloudKit.http.newCall(b.build()).execute().use { r ->
            val text = r.body?.string() ?: ""
            val o = runCatching { JSONObject(text) }.getOrElse { JSONObject() }
            if (r.code == 401 && auth) { store.webToken = ""; throw AuthNeeded("") }
            if (!r.isSuccessful) throw CloudError(o.optString("error").ifEmpty { "Server error ${r.code}" })
            return o
        }
    }

    /** Signs in with a Google ID token (or a "Move my account" code) and keeps the session token. */
    fun login(idToken: String, linkCode: String? = null) {
        val dev = JSONObject().put("id", deviceID).put("platform", "android").put("pushToken", store.secret("relay.push") ?: "")
        val req = JSONObject().put("provider", "google").put("idToken", idToken).put("device", dev)
        if (!linkCode.isNullOrBlank()) req.put("linkCode", linkCode.trim().uppercase())
        val o = call("POST", "/v1/login", req, auth = false)
        store.webToken = o.getString("token")
        deviceID = o.getString("deviceID")
        store.setSecret("relay.user", o.getString("userID"))
    }

    /** A one-time code (valid 10 minutes) to move this account to another phone. */
    fun moveCode(): String = call("POST", "/v1/link").getString("code")

    fun setPushToken(token: String) { call("PUT", "/v1/me/device", JSONObject().put("pushToken", token)) }

    /** Last-seen times (epoch ms) for these people; only those who share it. */
    fun seen(ids: List<String>): Map<String, Long> {
        if (ids.isEmpty() || store.webToken.isEmpty()) return emptyMap()
        val list = call("POST", "/v1/profiles", JSONObject().put("ids", JSONArray(ids)).put("seenOnly", true)).optJSONArray("profiles") ?: return emptyMap()
        val out = mutableMapOf<String, Long>()
        list.forEachObj { p -> p.optString("seen").takeIf { it.isNotEmpty() }?.let { runCatching { out[p.getString("userID")] = java.time.Instant.parse(it).toEpochMilli() } } }
        return out
    }

    /** Shares "online now" (the server stamps its own time). */
    fun touchSeen() { call("PUT", "/v1/me/seen", JSONObject().put("seen", java.time.Instant.now().toString())) }

    override fun signInURL(): String = ""

    override fun me(): String {
        if (store.webToken.isEmpty()) throw AuthNeeded("")
        return store.secret("relay.user") ?: throw AuthNeeded("")
    }

    override fun lookup(names: List<String>, keys: List<String>?): Map<String, JSONObject> = emptyMap()

    override fun profile(userID: String): Profile? {
        val list = call("POST", "/v1/profiles", JSONObject().put("ids", JSONArray().put(userID))).optJSONArray("profiles") ?: return null
        if (list.length() == 0) return null
        val p = list.getJSONObject(0)
        return Profile(p.getString("userID"), p.optString("name"), p.optString("pubkey"), p.optString("qr"), p.optString("pic"))
    }

    override fun saveProfile(userID: String, name: String, pubkey: String, replace: Boolean, pic: ByteArray?, clearPic: Boolean) {
        val o = JSONObject().put("name", name)
        if (replace) o.put("pubkey", pubkey)
        if (pic != null) o.put("pic", E2E.b64(pic)) else if (clearPic) o.put("pic", "")
        call("PUT", "/v1/me/profile", o)
    }

    override fun envelope(to: String, from: String, conv: String, kind: Int, loud: Boolean, body: ByteArray, hint: String?): JSONObject {
        val e = JSONObject().put("id", "E" + newID()).put("rcpt", to).put("conv", conv).put("kind", kind)
            .put("loud", loud).put("body", E2E.b64(body))
        if (hint != null) e.put("hint", E2E.b64(hint.toByteArray()))
        return JSONObject().put("relayEnvelope", e)
    }

    /** Only envelopes travel through the relay; other CloudKit record types are not available here. */
    override fun modify(ops: List<JSONObject>) {
        val envs = ops.mapNotNull { it.optJSONObject("relayEnvelope") }
        if (envs.size != ops.size) throw CloudError("Not available in iTeam Next yet")
        envs.chunked(300).forEach { chunk ->
            val o = call("POST", "/v1/send", JSONObject().put("envelopes", JSONArray(chunk)))
            val failed = o.optJSONObject("failed")
            if (failed != null && failed.length() > 0) throw CloudError("Not delivered: " + failed.getString(failed.keys().next()))
        }
    }

    override fun query(type: String, filters: JSONArray, keys: List<String>?, sortByCreated: Boolean, limit: Int): List<JSONObject> =
        throw CloudError("Not available in iTeam Next yet")

    override fun uploadBlob(name: String, sealed: ByteArray) { call("PUT", "/v1/blobs/$name", sealed) }

    override fun downloadBlob(name: String): ByteArray {
        if (store.webToken.isEmpty()) throw AuthNeeded("")
        val req = Request.Builder().url("$base/v1/blobs/$name").header("Authorization", "Bearer " + store.webToken).build()
        return CloudKit.http.newCall(req).execute().use { r ->
            if (r.code == 404) throw CloudError("File not found (files are kept 45 days)")
            if (!r.isSuccessful) throw CloudError("download ${r.code}")
            r.body?.bytes() ?: ByteArray(0)
        }
    }

    /**
     * New envelopes since the last call. The previous batch is acknowledged first — by then the app
     * has saved it — so the relay can delete it once every device of mine has it.
     */
    override fun inbox(me: String, sinceMs: Long): List<Incoming> {
        if (seq > acked) { call("POST", "/v1/ack", JSONObject().put("upTo", seq)); acked = seq }
        val out = mutableListOf<Incoming>()
        do {
            val o = call("GET", "/v1/inbox?after=$seq&limit=200")
            val list = o.optJSONArray("envelopes") ?: JSONArray()
            list.forEachObj { e ->
                val from = e.getString("sndr")
                val created = runCatching { java.time.Instant.parse(e.getString("created")).toEpochMilli() }.getOrDefault(System.currentTimeMillis())
                out += Incoming(e.getString("id"), from, from, e.optString("conv"), e.optInt("kind"), E2E.unb64(e.getString("body")), created)
                seq = maxOf(seq, e.getLong("seq"))
            }
        } while (o.optBoolean("more") && out.size < 2000)
        return out
    }
}
