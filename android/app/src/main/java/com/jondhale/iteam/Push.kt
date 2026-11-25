package com.jondhale.iteam

import android.content.Context
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage

/**
 * iTeam Next only: the relay sends a tiny push (no readable content) when something arrives.
 * The phone then fetches and decrypts it itself and shows the notification.
 */
class PushService : FirebaseMessagingService() {
    override fun onMessageReceived(msg: RemoteMessage) {
        if (!BuildConfig.RELAY) return
        val store = Store.get(applicationContext)
        if (store.me.isEmpty() || store.identity == null || store.webToken.isEmpty()) return
        try {
            Notify.show(applicationContext, Sync(store).poll())
            runCatching { ITeamWidget.update(applicationContext) }
        } catch (e: AuthNeeded) { Notify.signInNeeded(applicationContext) } catch (_: Exception) { PollWorker.schedule(applicationContext) }
    }

    override fun onNewToken(token: String) {
        if (!BuildConfig.RELAY) return
        val store = Store.get(applicationContext)
        store.setSecret("relay.push", token)
        if (store.webToken.isNotEmpty()) runCatching { RelayCloud(store).setPushToken(token) }
    }
}

object Push {
    /** Sends this phone's current push token to the relay (after sign-in and on every app start). */
    fun register(ctx: Context) {
        if (!BuildConfig.RELAY) return
        runCatching {
            FirebaseMessaging.getInstance().token.addOnSuccessListener { token ->
                val store = Store.get(ctx)
                store.setSecret("relay.push", token)
                if (store.webToken.isNotEmpty()) Thread { runCatching { RelayCloud(store).setPushToken(token) } }.start()
            }
        }
    }
}
