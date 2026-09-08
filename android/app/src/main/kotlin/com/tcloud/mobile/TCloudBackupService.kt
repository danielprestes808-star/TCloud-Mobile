package com.tcloud.mobile

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

class TCloudBackupService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private val maintenance = object : Runnable {
        override fun run() {
            if (!isEnabled(applicationContext)) {
                stopSelf()
                return
            }
            enqueueBackup(applicationContext)
            handler.postDelayed(this, MAINTENANCE_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
        startForeground(NOTIFICATION_ID, notification())
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!isEnabled(applicationContext)) {
            stopSelf()
            return START_NOT_STICKY
        }
        handler.removeCallbacks(maintenance)
        handler.post(maintenance)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(maintenance)
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Fechar a tela nao cancela a fila. O WorkManager permanece como
        // segunda camada caso o fabricante remova o processo da memoria.
        enqueueBackup(applicationContext)
        super.onTaskRemoved(rootIntent)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Backup automatico do TCloud",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Mantem fotos e videos sincronizados em segundo plano."
                setShowBadge(false)
            }
        )
    }

    private fun notification(): android.app.Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = launch?.let {
            PendingIntent.getActivity(
                this,
                4093,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("TCloud protegido em segundo plano")
            .setContentText("O backup automatico esta ativo.")
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pending)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "tcloud_backup_service"
        private const val NOTIFICATION_ID = 4093
        private const val SERVICE_WORK = "tcloud-gallery-service-cycle"
        private const val MAINTENANCE_INTERVAL_MS = 45_000L

        fun isEnabled(context: Context): Boolean =
            context.getSharedPreferences(TCloudGalleryWorker.PREFS, Context.MODE_PRIVATE)
                .getBoolean(TCloudGalleryWorker.KEY_ENABLED, false)

        fun start(context: Context) {
            if (!isEnabled(context)) return
            val intent = Intent(context, TCloudBackupService::class.java)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TCloudBackupService::class.java))
            WorkManager.getInstance(context).cancelUniqueWork(SERVICE_WORK)
        }

        fun enqueueBackup(context: Context) {
            if (!isEnabled(context)) return
            val prefs =
                context.getSharedPreferences(TCloudGalleryWorker.PREFS, Context.MODE_PRIVATE)
            val wifiOnly = prefs.getBoolean(TCloudGalleryWorker.KEY_WIFI_ONLY, false)
            val chargingOnly =
                prefs.getBoolean(TCloudGalleryWorker.KEY_REQUIRES_CHARGING, false)
            val constraints = Constraints.Builder()
                .setRequiredNetworkType(
                    if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
                )
                .setRequiresCharging(chargingOnly)
                .setRequiresStorageNotLow(true)
                .build()
            val request = OneTimeWorkRequestBuilder<TCloudGalleryWorker>()
                .setConstraints(constraints)
                .setBackoffCriteria(BackoffPolicy.LINEAR, 30, TimeUnit.SECONDS)
                .addTag("tcloud_gallery_persistent")
                .build()
            WorkManager.getInstance(context).enqueueUniqueWork(
                SERVICE_WORK,
                ExistingWorkPolicy.KEEP,
                request
            )
        }
    }
}
