package com.tcloud.mobile

import android.Manifest
import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import java.io.File
import java.util.Locale
import kotlin.math.roundToInt

object TCloudUpdateNotifications {
    private const val CHANNEL_ID =
        "tcloud_update_downloads"

    private const val CHANNEL_NAME =
        "Atualizacoes do TCloud"

    private const val NOTIFICATION_ID =
        10921

    private const val REQUEST_PERMISSION =
        10922

    fun ensurePermission(
        activity: Activity
    ): Boolean {
        ensureChannel(activity)

        if (
            Build.VERSION.SDK_INT <
            Build.VERSION_CODES.TIRAMISU
        ) {
            return true
        }

        if (
            activity.checkSelfPermission(
                Manifest.permission.POST_NOTIFICATIONS
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            return true
        }

        activity.requestPermissions(
            arrayOf(
                Manifest.permission.POST_NOTIFICATIONS
            ),
            REQUEST_PERMISSION
        )

        return false
    }

    fun showProgress(
        context: Context,
        version: String,
        received: Long,
        total: Long
    ) {
        ensureChannel(context)

        if (!canNotify(context)) {
            return
        }

        val safeReceived =
            received.coerceAtLeast(0L)

        val safeTotal =
            total.coerceAtLeast(0L)

        val determinate =
            safeTotal > 0L

        val percent =
            if (determinate) {
                (
                    safeReceived.toDouble() /
                        safeTotal.toDouble() *
                        100.0
                )
                    .roundToInt()
                    .coerceIn(0, 100)
            } else {
                0
            }

        val text =
            if (determinate) {
                "$percent%  â€¢  " +
                    formatBytes(safeReceived) +
                    " / " +
                    formatBytes(safeTotal)
            } else {
                "Preparando download..."
            }

        val builder =
            builder(context)
                .setSmallIcon(
                    android.R.drawable.stat_sys_download
                )
                .setContentTitle(
                    "Baixando atualizacao $version"
                )
                .setContentText(text)
                .setContentIntent(
                    openAppIntent(context)
                )
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setAutoCancel(false)
                .setCategory(
                    Notification.CATEGORY_PROGRESS
                )
                .setProgress(
                    100,
                    percent,
                    !determinate
                )

        manager(context).notify(
            NOTIFICATION_ID,
            builder.build()
        )
    }

    fun showReady(
        context: Context,
        version: String,
        path: String
    ) {
        ensureChannel(context)

        if (!canNotify(context)) {
            return
        }

        val file = File(path)

        if (!file.exists() || !file.isFile) {
            showFailed(
                context,
                version,
                "APK nao encontrado."
            )
            return
        }

        val canInstall =
            canInstallPackages(context)

        val action =
            if (canInstall) {
                installPendingIntent(
                    context,
                    file
                )
            } else {
                installPermissionIntent(
                    context
                )
            }

        val text =
            if (canInstall) {
                "Toque para instalar agora."
            } else {
                "Toque para autorizar a instalacao."
            }

        val builder =
            builder(context)
                .setSmallIcon(
                    android.R.drawable.stat_sys_download_done
                )
                .setContentTitle(
                    "Atualizacao $version pronta"
                )
                .setContentText(text)
                .setContentIntent(action)
                .setAutoCancel(true)
                .setOngoing(false)
                .setProgress(0, 0, false)
                .setCategory(
                    Notification.CATEGORY_STATUS
                )

        manager(context).notify(
            NOTIFICATION_ID,
            builder.build()
        )
    }

    fun showFailed(
        context: Context,
        version: String,
        message: String
    ) {
        ensureChannel(context)

        if (!canNotify(context)) {
            return
        }

        val cleanMessage =
            message
                .replace('\n', ' ')
                .trim()
                .take(120)

        val text =
            if (cleanMessage.isBlank()) {
                "Toque para tentar novamente."
            } else {
                cleanMessage
            }

        val builder =
            builder(context)
                .setSmallIcon(
                    android.R.drawable.stat_notify_error
                )
                .setContentTitle(
                    "Falha ao baixar $version"
                )
                .setContentText(text)
                .setContentIntent(
                    openAppIntent(context)
                )
                .setAutoCancel(true)
                .setOngoing(false)
                .setProgress(0, 0, false)
                .setCategory(
                    Notification.CATEGORY_ERROR
                )

        manager(context).notify(
            NOTIFICATION_ID,
            builder.build()
        )
    }

    private fun ensureChannel(
        context: Context
    ) {
        if (
            Build.VERSION.SDK_INT <
            Build.VERSION_CODES.O
        ) {
            return
        }

        val channel =
            NotificationChannel(
                CHANNEL_ID,
                CHANNEL_NAME,
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description =
                    "Progresso de download e instalacao das atualizacoes do TCloud."
                setSound(null, null)
                enableVibration(false)
            }

        manager(context).createNotificationChannel(
            channel
        )
    }

    private fun canNotify(
        context: Context
    ): Boolean {
        if (
            Build.VERSION.SDK_INT <
            Build.VERSION_CODES.TIRAMISU
        ) {
            return true
        }

        return context.checkSelfPermission(
            Manifest.permission.POST_NOTIFICATIONS
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun builder(
        context: Context
    ): Notification.Builder {
        return if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.O
        ) {
            Notification.Builder(
                context,
                CHANNEL_ID
            )
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(context)
        }
    }

    private fun manager(
        context: Context
    ): NotificationManager {
        return context.getSystemService(
            Context.NOTIFICATION_SERVICE
        ) as NotificationManager
    }

    private fun immutableFlag(): Int {
        return if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.M
        ) {
            PendingIntent.FLAG_IMMUTABLE
        } else {
            0
        }
    }

    private fun openAppIntent(
        context: Context
    ): PendingIntent {
        val intent =
            context.packageManager
                .getLaunchIntentForPackage(
                    context.packageName
                )
                ?: Intent(
                    context,
                    MainActivity::class.java
                )

        intent.addFlags(
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        )

        return PendingIntent.getActivity(
            context,
            10923,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                immutableFlag()
        )
    }

    private fun installPendingIntent(
        context: Context,
        file: File
    ): PendingIntent {
        val uri =
            FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                file
            )

        val intent =
            Intent(
                Intent.ACTION_VIEW
            ).apply {
                setDataAndType(
                    uri,
                    "application/vnd.android.package-archive"
                )
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_ACTIVITY_NEW_TASK
                )
            }

        return PendingIntent.getActivity(
            context,
            10924,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                immutableFlag()
        )
    }

    private fun installPermissionIntent(
        context: Context
    ): PendingIntent {
        val intent =
            if (
                Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.O
            ) {
                Intent(
                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    Uri.parse(
                        "package:${context.packageName}"
                    )
                )
            } else {
                context.packageManager
                    .getLaunchIntentForPackage(
                        context.packageName
                    )
                    ?: Intent(
                        context,
                        MainActivity::class.java
                    )
            }

        intent.addFlags(
            Intent.FLAG_ACTIVITY_NEW_TASK
        )

        return PendingIntent.getActivity(
            context,
            10925,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or
                immutableFlag()
        )
    }

    private fun canInstallPackages(
        context: Context
    ): Boolean {
        if (
            Build.VERSION.SDK_INT <
            Build.VERSION_CODES.O
        ) {
            return true
        }

        return context.packageManager
            .canRequestPackageInstalls()
    }

    private fun formatBytes(
        bytes: Long
    ): String {
        val safe =
            bytes.coerceAtLeast(0L)

        val mb =
            safe.toDouble() /
                (1024.0 * 1024.0)

        return String.format(
            Locale.US,
            "%.1f MB",
            mb
        )
    }
}
