package com.jondhale.iteam

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/** No push server: Android checks the mailbox every 15 minutes in the background (the shortest Android allows). */
class PollWorker(ctx: Context, params: WorkerParameters) : CoroutineWorker(ctx, params) {
    override suspend fun doWork(): Result {
        val store = Store.get(applicationContext)
        if (store.me.isEmpty() || store.webToken.isEmpty() || store.identity == null) return Result.success()
        return try {
            Notify.show(applicationContext, Sync(store).poll()); ITeamWidget.update(applicationContext); Result.success()
        } catch (e: AuthNeeded) { Result.success() } catch (e: Exception) { Result.retry() }
    }

    companion object {
        fun schedule(ctx: Context) {
            val req = PeriodicWorkRequestBuilder<PollWorker>(15, TimeUnit.MINUTES)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()).build()
            WorkManager.getInstance(ctx).enqueueUniquePeriodicWork("poll", ExistingPeriodicWorkPolicy.KEEP, req)
        }
    }
}

object Notify {
    private const val CH = "messages"
    var foregroundConv: String? = null

    fun show(ctx: Context, notices: List<Sync.Notice>) {
        if (notices.isEmpty()) return
        if (ContextCompat.checkSelfPermission(ctx, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        val nm = ctx.getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CH, "Messages", NotificationManager.IMPORTANCE_HIGH))
        for (n in notices.filter { it.conv != foregroundConv }.takeLast(5)) {
            val open = PendingIntent.getActivity(ctx, n.conv.hashCode(), Intent(ctx, MainActivity::class.java).putExtra("conv", n.conv),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val note = NotificationCompat.Builder(ctx, CH).setSmallIcon(R.drawable.ic_launcher).setContentTitle(n.title)
                .setContentText(n.text).setStyle(NotificationCompat.BigTextStyle().bigText(n.text)).setAutoCancel(true).setContentIntent(open).build()
            NotificationManagerCompat.from(ctx).notify(n.conv.hashCode(), note)
        }
    }
}
