package com.tcloud.mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

class TCloudUpdateDownloadService : Service() {
    companion object {
        private const val CHANNEL_ID =
            "tcloud_update_downloads"

        private const val CHANNEL_NAME =
            "Atualizacoes do TCloud"

        private const val NOTIFICATION_ID =
            10921

        private const val PREFS =
            "tcloud_update_native_download_v1"

        private const val KEY_STATUS =
            "status"

        private const val KEY_RECEIVED =
            "received"

        private const val KEY_TOTAL =
            "total"

        private const val KEY_PATH =
            "path"

        private const val KEY_ERROR =
            "error"

        private const val KEY_VERSION =
            "version"

        private const val KEY_URL =
            "url"

        private const val KEY_SHA256 =
            "sha256"

        private val running =
            AtomicBoolean(false)

        fun start(
            context: Context,
            url: String,
            version: String,
            sha256: String
        ) {
            val cleanUrl = url.trim()
            val cleanVersion = version.trim()
            val cleanSha =
                sha256.trim().lowercase(Locale.US)

            if (
                cleanUrl.isBlank() ||
                cleanVersion.isBlank() ||
                cleanSha.length != 64
            ) {
                throw IllegalArgumentException(
                    "Dados da atualizacao invalidos."
                )
            }

            val finalFile =
                File(
                    File(
                        context.cacheDir,
                        "updates"
                    ),
                    "tcloud-mobile-update.apk"
                )

            val prefs =
                context.getSharedPreferences(
                    PREFS,
                    Context.MODE_PRIVATE
                )

            val previousStatus =
                prefs.getString(
                    KEY_STATUS,
                    ""
                ).orEmpty()

            val previousSha =
                prefs.getString(
                    KEY_SHA256,
                    ""
                ).orEmpty()

            if (
                previousStatus == "completed" &&
                previousSha == cleanSha &&
                finalFile.exists() &&
                finalFile.isFile
            ) {
                return
            }

            prefs.edit()
                .putString(KEY_STATUS, "starting")
                .putString(KEY_URL, cleanUrl)
                .putString(KEY_VERSION, cleanVersion)
                .putString(KEY_SHA256, cleanSha)
                .putString(KEY_ERROR, "")
                .apply()

            val intent =
                Intent(
                    context,
                    TCloudUpdateDownloadService::class.java
                ).apply {
                    putExtra("url", cleanUrl)
                    putExtra("version", cleanVersion)
                    putExtra("sha256", cleanSha)
                }

            if (
                Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.O
            ) {
                context.startForegroundService(
                    intent
                )
            } else {
                context.startService(
                    intent
                )
            }
        }

        fun status(
            context: Context
        ): Map<String, Any?> {
            val prefs =
                context.getSharedPreferences(
                    PREFS,
                    Context.MODE_PRIVATE
                )

            return mapOf(
                "status" to
                    prefs.getString(
                        KEY_STATUS,
                        "idle"
                    ).orEmpty(),
                "received" to
                    prefs.getLong(
                        KEY_RECEIVED,
                        0L
                    ),
                "total" to
                    prefs.getLong(
                        KEY_TOTAL,
                        0L
                    ),
                "path" to
                    prefs.getString(
                        KEY_PATH,
                        ""
                    ).orEmpty(),
                "error" to
                    prefs.getString(
                        KEY_ERROR,
                        ""
                    ).orEmpty(),
                "version" to
                    prefs.getString(
                        KEY_VERSION,
                        ""
                    ).orEmpty()
            )
        }
    }

    private val executor =
        Executors.newSingleThreadExecutor()

    override fun onBind(
        intent: Intent?
    ): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        val url =
            intent
                ?.getStringExtra("url")
                ?.trim()
                .orEmpty()

        val version =
            intent
                ?.getStringExtra("version")
                ?.trim()
                .orEmpty()

        val sha256 =
            intent
                ?.getStringExtra("sha256")
                ?.trim()
                ?.lowercase(Locale.US)
                .orEmpty()

        if (
            url.isBlank() ||
            version.isBlank() ||
            sha256.length != 64
        ) {
            stopSelf()
            return START_NOT_STICKY
        }

        startForeground(
            NOTIFICATION_ID,
            buildProgressNotification(
                version,
                0L,
                0L
            )
        )

        if (
            running.compareAndSet(
                false,
                true
            )
        ) {
            executor.execute {
                try {
                    runDownload(
                        url,
                        version,
                        sha256
                    )
                } finally {
                    running.set(false)
                }
            }
        }

        return START_REDELIVER_INTENT
    }

    private fun runDownload(
        url: String,
        version: String,
        expectedSha: String
    ) {
        val prefs =
            getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE
            )

        val dir =
            File(
                cacheDir,
                "updates"
            )

        dir.mkdirs()

        val finalFile =
            File(
                dir,
                "tcloud-mobile-update.apk"
            )

        val partFile =
            File(
                dir,
                "tcloud-mobile-update.apk.part"
            )

        try {
            if (
                finalFile.exists() &&
                sha256(finalFile) ==
                    expectedSha
            ) {
                markCompleted(
                    prefs,
                    version,
                    finalFile
                )

                TCloudUpdateNotifications
                    .showReady(
                        this,
                        version,
                        finalFile.absolutePath
                    )

                detachForeground()
                stopSelf()
                return
            }

            if (finalFile.exists()) {
                finalFile.delete()
            }

            updateState(
                prefs,
                "downloading",
                partFile.length(),
                0L,
                "",
                ""
            )

            var success = false
            var lastError: Throwable? = null

            for (attempt in 1..10) {
                try {
                    downloadAttempt(
                        url,
                        version,
                        partFile,
                        prefs
                    )

                    success = true
                    break
                } catch (
                    error: Throwable
                ) {
                    lastError = error

                    if (attempt >= 10) {
                        break
                    }

                    try {
                        Thread.sleep(
                            (attempt * 1500L)
                                .coerceAtMost(
                                    10000L
                                )
                        )
                    } catch (
                        _: InterruptedException
                    ) {
                    }
                }
            }

            if (!success) {
                throw lastError
                    ?: IOException(
                        "Falha no download."
                    )
            }

            val actualSha =
                sha256(partFile)

            if (
                actualSha != expectedSha
            ) {
                partFile.delete()

                throw IOException(
                    "SHA-256 da atualizacao nao confere."
                )
            }

            if (finalFile.exists()) {
                finalFile.delete()
            }

            if (
                !partFile.renameTo(
                    finalFile
                )
            ) {
                partFile.copyTo(
                    finalFile,
                    overwrite = true
                )

                partFile.delete()
            }

            markCompleted(
                prefs,
                version,
                finalFile
            )

            TCloudUpdateNotifications
                .showReady(
                    this,
                    version,
                    finalFile.absolutePath
                )

            detachForeground()
            stopSelf()
        } catch (
            error: Throwable
        ) {
            val message =
                error.message
                    ?.trim()
                    ?.take(180)
                    .orEmpty()
                    .ifBlank {
                        error
                            .javaClass
                            .simpleName
                    }

            updateState(
                prefs,
                "failed",
                partFile.length(),
                prefs.getLong(
                    KEY_TOTAL,
                    0L
                ),
                "",
                message
            )

            TCloudUpdateNotifications
                .showFailed(
                    this,
                    version,
                    message
                )

            detachForeground()
            stopSelf()
        }
    }

    private fun downloadAttempt(
        sourceUrl: String,
        version: String,
        partFile: File,
        prefs:
            android.content.SharedPreferences
    ) {
        var existing =
            if (
                partFile.exists()
            ) {
                partFile.length()
            } else {
                0L
            }

        val connection =
            (
                URL(sourceUrl)
                    .openConnection()
                    as HttpURLConnection
            ).apply {
                instanceFollowRedirects = true
                connectTimeout = 20000
                readTimeout = 30000
                requestMethod = "GET"

                setRequestProperty(
                    "User-Agent",
                    "TCloud-Mobile-Native-Updater"
                )

                if (existing > 0L) {
                    setRequestProperty(
                        "Range",
                        "bytes=$existing-"
                    )
                }
            }

        try {
            connection.connect()

            val code =
                connection.responseCode

            val append =
                existing > 0L &&
                    code ==
                    HttpURLConnection.HTTP_PARTIAL

            if (
                code ==
                    HttpURLConnection.HTTP_OK
            ) {
                if (existing > 0L) {
                    partFile.delete()
                    existing = 0L
                }
            } else if (
                code !=
                    HttpURLConnection.HTTP_PARTIAL
            ) {
                throw IOException(
                    "Servidor retornou HTTP $code."
                )
            }

            val contentLength =
                connection.contentLengthLong

            val total =
                if (
                    contentLength > 0L
                ) {
                    if (append) {
                        existing +
                            contentLength
                    } else {
                        contentLength
                    }
                } else {
                    0L
                }

            var received =
                existing

            var lastPercent =
                -1

            var lastNotifyAt =
                0L

            FileOutputStream(
                partFile,
                append
            ).buffered(
                256 * 1024
            ).use {
                    output ->
                connection
                    .inputStream
                    .buffered(
                        256 * 1024
                    )
                    .use {
                            input ->
                        val buffer =
                            ByteArray(
                                256 * 1024
                            )

                        while (true) {
                            val read =
                                input.read(
                                    buffer
                                )

                            if (read < 0) {
                                break
                            }

                            if (read == 0) {
                                continue
                            }

                            output.write(
                                buffer,
                                0,
                                read
                            )

                            received +=
                                read.toLong()

                            val now =
                                System
                                    .currentTimeMillis()

                            val percent =
                                if (
                                    total > 0L
                                ) {
                                    (
                                        received
                                            .toDouble() /
                                            total
                                                .toDouble() *
                                            100.0
                                    )
                                        .roundToInt()
                                        .coerceIn(
                                            0,
                                            100
                                        )
                                } else {
                                    -1
                                }

                            if (
                                percent !=
                                    lastPercent ||
                                now -
                                    lastNotifyAt >=
                                    800L
                            ) {
                                lastPercent =
                                    percent
                                lastNotifyAt =
                                    now

                                updateState(
                                    prefs,
                                    "downloading",
                                    received,
                                    total,
                                    "",
                                    ""
                                )

                                notificationManager()
                                    .notify(
                                        NOTIFICATION_ID,
                                        buildProgressNotification(
                                            version,
                                            received,
                                            total
                                        )
                                    )
                            }
                        }

                        output.flush()
                    }
            }

            if (
                total > 0L &&
                received < total
            ) {
                throw IOException(
                    "Conexao terminou antes do fim: "
                        + "$received de $total bytes."
                )
            }

            updateState(
                prefs,
                "verifying",
                received,
                if (
                    total > 0L
                ) {
                    total
                } else {
                    received
                },
                "",
                ""
            )
        } finally {
            connection.disconnect()
        }
    }

    private fun markCompleted(
        prefs:
            android.content.SharedPreferences,
        version: String,
        file: File
    ) {
        val size =
            file.length()

        prefs.edit()
            .putString(
                KEY_STATUS,
                "completed"
            )
            .putLong(
                KEY_RECEIVED,
                size
            )
            .putLong(
                KEY_TOTAL,
                size
            )
            .putString(
                KEY_PATH,
                file.absolutePath
            )
            .putString(
                KEY_ERROR,
                ""
            )
            .putString(
                KEY_VERSION,
                version
            )
            .apply()
    }

    private fun updateState(
        prefs:
            android.content.SharedPreferences,
        status: String,
        received: Long,
        total: Long,
        path: String,
        error: String
    ) {
        prefs.edit()
            .putString(
                KEY_STATUS,
                status
            )
            .putLong(
                KEY_RECEIVED,
                received
                    .coerceAtLeast(
                        0L
                    )
            )
            .putLong(
                KEY_TOTAL,
                total
                    .coerceAtLeast(
                        0L
                    )
            )
            .putString(
                KEY_PATH,
                path
            )
            .putString(
                KEY_ERROR,
                error
            )
            .apply()
    }

    private fun ensureChannel() {
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
                NotificationManager
                    .IMPORTANCE_LOW
            ).apply {
                description =
                    "Download de atualizacoes do TCloud."
                setSound(
                    null,
                    null
                )
                enableVibration(
                    false
                )
            }

        notificationManager()
            .createNotificationChannel(
                channel
            )
    }

    private fun buildProgressNotification(
        version: String,
        received: Long,
        total: Long
    ): Notification {
        val determinate =
            total > 0L

        val percent =
            if (
                determinate
            ) {
                (
                    received
                        .toDouble() /
                        total
                            .toDouble() *
                        100.0
                )
                    .roundToInt()
                    .coerceIn(
                        0,
                        100
                    )
            } else {
                0
            }

        val text =
            if (
                determinate
            ) {
                "${percent}%  â€¢  ${formatBytes(received)} / ${formatBytes(total)}"
            } else {
                "Conectando..."
            }

        val openIntent =
            packageManager
                .getLaunchIntentForPackage(
                    packageName
                )
                ?: Intent(
                    this,
                    MainActivity::class.java
                )

        openIntent.addFlags(
            Intent.FLAG_ACTIVITY_CLEAR_TOP or
                Intent.FLAG_ACTIVITY_SINGLE_TOP
        )

        val pending =
            PendingIntent.getActivity(
                this,
                10931,
                openIntent,
                PendingIntent
                    .FLAG_UPDATE_CURRENT or
                    immutableFlag()
            )

        val builder =
            if (
                Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.O
            ) {
                Notification.Builder(
                    this,
                    CHANNEL_ID
                )
            } else {
                @Suppress(
                    "DEPRECATION"
                )
                Notification.Builder(
                    this
                )
            }

        return builder
            .setSmallIcon(
                android.R.drawable
                    .stat_sys_download
            )
            .setContentTitle(
                "Baixando TCloud $version"
            )
            .setContentText(
                text
            )
            .setContentIntent(
                pending
            )
            .setOnlyAlertOnce(
                true
            )
            .setOngoing(
                true
            )
            .setCategory(
                Notification
                    .CATEGORY_PROGRESS
            )
            .setProgress(
                100,
                percent,
                !determinate
            )
            .build()
    }

    private fun notificationManager():
        NotificationManager {
        return getSystemService(
            Context.NOTIFICATION_SERVICE
        ) as NotificationManager
    }

    private fun immutableFlag():
        Int {
        return if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.M
        ) {
            PendingIntent
                .FLAG_IMMUTABLE
        } else {
            0
        }
    }

    private fun formatBytes(
        bytes: Long
    ): String {
        val mb =
            bytes
                .coerceAtLeast(
                    0L
                )
                .toDouble() /
                (
                    1024.0 *
                        1024.0
                    )

        return String.format(
            Locale.US,
            "%.1f MB",
            mb
        )
    }

    private fun sha256(
        file: File
    ): String {
        val digest =
            MessageDigest
                .getInstance(
                    "SHA-256"
                )

        file.inputStream()
            .buffered(
                1024 * 1024
            )
            .use {
                    input ->
                val buffer =
                    ByteArray(
                        1024 * 1024
                    )

                while (true) {
                    val read =
                        input.read(
                            buffer
                        )

                    if (read <= 0) {
                        break
                    }

                    digest.update(
                        buffer,
                        0,
                        read
                    )
                }
            }

        return digest
            .digest()
            .joinToString(
                ""
            ) {
                    byte ->
                "%02x".format(
                    byte.toInt() and
                        0xff
                )
            }
    }

    private fun detachForeground() {
        if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.N
        ) {
            stopForeground(
                STOP_FOREGROUND_DETACH
            )
        } else {
            @Suppress(
                "DEPRECATION"
            )
            stopForeground(
                false
            )
        }
    }
}
