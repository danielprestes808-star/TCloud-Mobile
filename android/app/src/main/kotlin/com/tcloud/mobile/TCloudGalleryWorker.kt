package com.tcloud.mobile

import android.content.ContentUris
import android.content.Context
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.pm.ServiceInfo
import android.os.Build
import android.provider.MediaStore
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.Worker
import androidx.work.WorkerParameters
import androidx.work.WorkManager
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.TimeUnit

class TCloudGalleryWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : Worker(appContext, workerParams) {

    override fun doWork(): Result {
        return try {
            scanAndQueue()

            val before =
                queueLength()

            // TCLOUD_BACKGROUND_PROGRESS_1052
            if (before > 0) {
                setForegroundAsync(foregroundInfo(before)).get()
                notifyBackupStatus(
                    before = before,
                    remaining = before,
                    completed = false
                )
            }

            val completed =
                TCloudTdlibRuntime
                    .processBackgroundQueue(
                        applicationContext
                    )

            val after =
                queueLength()

            if (before > 0) {
                notifyBackupStatus(
                    before = before,
                    remaining = after,
                    completed = completed
                )
            }

            if (completed) {
                Result.success()
            } else {
                val blockedUntil =
                    applicationContext.getSharedPreferences(
                        PREFS,
                        Context.MODE_PRIVATE
                    ).getLong(KEY_RATE_LIMIT_UNTIL, 0L)

                if (blockedUntil > System.currentTimeMillis()) {
                    enqueueContinuation(
                        blockedUntil - System.currentTimeMillis()
                    )
                    Result.success()
                } else {
                    Result.retry()
                }
            }
        } catch (_: SecurityException) {
            Result.failure()
        } catch (_: Throwable) {
            Result.retry()
        }
    }

    private fun queueLength(): Int {
        return TCloudBackgroundQueueStore.count(applicationContext)
    }

    private fun notifyBackupStatus(
        before: Int,
        remaining: Int,
        completed: Boolean
    ) {
        try {
            ensureNotificationChannel()
            if (
                android.os.Build.VERSION.SDK_INT >=
                    android.os.Build.VERSION_CODES.TIRAMISU &&
                androidx.core.content.ContextCompat.checkSelfPermission(
                    applicationContext,
                    android.Manifest.permission.POST_NOTIFICATIONS
                ) != android.content.pm.PackageManager.PERMISSION_GRANTED
            ) {
                return
            }

            val sent =
                (before - remaining)
                    .coerceAtLeast(0)

            val title =
                if (remaining == 0 && completed) {
                    "Backup do TCloud concluido"
                } else if (sent > 0) {
                    "Backup do TCloud atualizado"
                } else {
                    "Backup do TCloud aguardando"
                }

            val text =
                when {
                    remaining == 0 &&
                        completed ->
                        "$before item(ns) processado(s)."

                    sent > 0 ->
                        "$sent enviado(s), $remaining aguardando."

                    else ->
                        "$remaining item(ns) aguardando nova tentativa."
                }

            val notification =
                NotificationCompat.Builder(
                    applicationContext,
                    CHANNEL_ID
                )
                    .setSmallIcon(
                        android.R.drawable.stat_sys_upload_done
                    )
                    .setContentTitle(title)
                    .setContentText(text)
                    .setOnlyAlertOnce(true)
                    .setOngoing(!completed && remaining > 0)
                    .setAutoCancel(completed || remaining == 0)
                    .setPriority(
                        NotificationCompat.PRIORITY_LOW
                    )
                    .build()

            NotificationManagerCompat
                .from(applicationContext)
                .notify(
                    NOTIFICATION_ID,
                    notification
                )
        } catch (_: Throwable) {}
    }
    private fun scanAndQueue() {
        val prefs =
            applicationContext.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE
            )

        val enabled =
            prefs.getBoolean(
                KEY_ENABLED,
                false
            )

        if (!enabled) {
            return
        }

        val hiddenAlbums =
            prefs.getStringSet(KEY_HIDDEN_ALBUMS, emptySet())
                ?.map { it.trim().lowercase() }
                ?.toSet()
                ?: emptySet()

        val previous =
            prefs.getLong(
                KEY_LAST_SCAN,
                0L
            )

        val sinceSeconds =
            if (previous <= 0L) {
                0L
            } else {
                ((previous - 120000L) / 1000L)
                    .coerceAtLeast(0L)
            }

        val queueFile =
            File(
                applicationContext.filesDir,
                QUEUE_FILE
            )

        val existing =
            readQueue(queueFile)

        val knownUris =
            mutableSetOf<String>()

        val uploadedUris =
            prefs.getStringSet(
                KEY_UPLOADED_URIS,
                emptySet()
            )?.toMutableSet()
                ?: mutableSetOf()

        for (index in 0 until existing.length()) {
            val item =
                existing.optJSONObject(index)
                    ?: continue

            val uri =
                item.optString("uri")

            if (uri.isNotBlank()) {
                knownUris.add(uri)
            }
        }

        val collection =
            MediaStore.Files.getContentUri(
                "external"
            )

        val columns =
            mutableListOf(
                MediaStore.Files.FileColumns._ID,
                MediaStore.Files.FileColumns.DISPLAY_NAME,
                MediaStore.Files.FileColumns.MIME_TYPE,
                MediaStore.Files.FileColumns.SIZE,
                MediaStore.Files.FileColumns.DATE_ADDED,
                MediaStore.Files.FileColumns.MEDIA_TYPE,
                MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME
            )
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            columns.add(MediaStore.Files.FileColumns.RELATIVE_PATH)
        }
        val projection = columns.toTypedArray()

        val selection =
            "(" +
                MediaStore.Files.FileColumns.MEDIA_TYPE +
                "=? OR " +
                MediaStore.Files.FileColumns.MEDIA_TYPE +
                "=?) AND " +
                MediaStore.Files.FileColumns.DATE_ADDED +
                ">=?"

        val args =
            arrayOf(
                MediaStore.Files.FileColumns
                    .MEDIA_TYPE_IMAGE
                    .toString(),
                MediaStore.Files.FileColumns
                    .MEDIA_TYPE_VIDEO
                    .toString(),
                sinceSeconds.toString()
            )

        var maxDateMs = previous

        applicationContext.contentResolver.query(
            collection,
            projection,
            selection,
            args,
            MediaStore.Files.FileColumns.DATE_ADDED +
                " ASC"
        )?.use { cursor ->
            val idIndex =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Files.FileColumns._ID
                )

            val nameIndex =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Files.FileColumns.DISPLAY_NAME
                )

            val mimeIndex =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Files.FileColumns.MIME_TYPE
                )

            val sizeIndex =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Files.FileColumns.SIZE
                )

            val dateIndex =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Files.FileColumns.DATE_ADDED
                )

            val mediaIndex =
                cursor.getColumnIndexOrThrow(
                    MediaStore.Files.FileColumns.MEDIA_TYPE
                )

            val bucketIndex =
                cursor.getColumnIndex(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
            val relativeIndex =
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q)
                    cursor.getColumnIndex(MediaStore.Files.FileColumns.RELATIVE_PATH)
                else -1


            while (cursor.moveToNext()) {
                val id =
                    cursor.getLong(idIndex)

                val uri =
                    ContentUris.withAppendedId(
                        collection,
                        id
                    ).toString()

                val dateMs =
                    cursor.getLong(dateIndex) *
                        1000L

                if (dateMs > maxDateMs) {
                    maxDateMs = dateMs
                }

                if (
                    knownUris.contains(uri) ||
                    uploadedUris.contains(uri)
                ) {
                    continue
                }

                val mediaType =
                    cursor.getInt(mediaIndex)

                val relativePath =
                    if (relativeIndex >= 0) cursor.getString(relativeIndex).orEmpty()
                    else ""
                val bucket =
                    if (bucketIndex >= 0) cursor.getString(bucketIndex).orEmpty()
                    else ""
                val genericAlbums =
                    setOf(
                        "", "outros", "other", "others", "galeria", "gallery",
                        "pictures", "picture", "images", "image", "media", "android",
                        "dcim", "download", "downloads", "movies", "videos", "video"
                    )
                fun genericAlbum(value: String): Boolean =
                    value.trim().lowercase() in genericAlbums
                fun packageAlbum(value: String): Boolean =
                    Regex(
                        "^[a-z0-9_]+(?:\\.[a-z0-9_]+){1,}$",
                        RegexOption.IGNORE_CASE
                    ).matches(value.trim())
                val pathAlbum =
                    relativePath
                        .replace('\\', '/')
                        .split('/')
                        .map { it.trim() }
                        .filter { it.isNotBlank() && !it.startsWith(".") }
                        .asReversed()
                        .firstOrNull {
                            !genericAlbum(it) && !packageAlbum(it)
                        }
                        .orEmpty()
                val album =
                    when {
                        pathAlbum.isNotBlank() -> pathAlbum
                        bucket.isNotBlank() && !genericAlbum(bucket) -> bucket.trim()
                        else -> "Outros"
                    }

                if (hiddenAlbums.contains(album.trim().lowercase())) {
                    continue
                }

                val item =
                    JSONObject().apply {
                        put("uri", uri)
                        put(
                            "name",
                            cursor.getString(nameIndex)
                                ?: ""
                        )
                        put(
                            "mime",
                            cursor.getString(mimeIndex)
                                ?: ""
                        )
                        put(
                            "size",
                            cursor.getLong(sizeIndex)
                        )
                        put("dateMs", dateMs)
                        put(
                            "kind",
                            if (
                                mediaType ==
                                    MediaStore.Files
                                        .FileColumns
                                        .MEDIA_TYPE_VIDEO
                            ) {
                                "video"
                            } else {
                                "image"
                            }
                        )
                        put("album", album)
                        put("relativePath", relativePath)
                        put("attempts", 0)
                    }

                existing.put(item)
                knownUris.add(uri)
            }
        }

        trimQueue(existing, 4000)
        writeQueue(queueFile, existing)

        if (maxDateMs > 0L) {
            prefs.edit()
                .putLong(
                    KEY_LAST_SCAN,
                    maxDateMs
                )
                .apply()
        }
    }

    private fun readQueue(
        file: File
    ): JSONArray {
        return TCloudBackgroundQueueStore.read(applicationContext)
    }

    private fun writeQueue(
        file: File,
        values: JSONArray
    ) {
        TCloudBackgroundQueueStore.mergeScanned(applicationContext, values, 4000)
    }

    private fun trimQueue(
        values: JSONArray,
        maximum: Int
    ) {
        while (values.length() > maximum) {
            values.remove(0)
        }
    }

    companion object {
        const val CHANNEL_ID =
            "tcloud_backup"

        const val NOTIFICATION_ID =
            4091

        const val CONTINUATION_NAME =
            "tcloud-gallery-continuation"

        const val UNIQUE_NAME =
            "tcloud-gallery-background-scan"

        const val PREFS =
            "tcloud_background"

        const val KEY_ENABLED =
            "gallery_enabled"

        const val KEY_LAST_SCAN =
            "gallery_last_scan"

        const val QUEUE_FILE =
            "tcloud_gallery_background_queue.json"

        const val KEY_UPLOADED_URIS =
            "gallery_uploaded_uris"

        const val KEY_WIFI_ONLY =
            "gallery_wifi_only"

        const val KEY_REQUIRES_CHARGING =
            "gallery_requires_charging"

        const val KEY_RATE_LIMIT_UNTIL =
            "gallery_rate_limit_until_ms_v1"

        const val KEY_HIDDEN_ALBUMS =
            "gallery_hidden_albums_v1"
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager =
            applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Backup do TCloud",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description =
                    "Mantem o backup ativo quando o aplicativo esta fechado."
                setShowBadge(false)
            }
        )
    }

    private fun foregroundInfo(total: Int): ForegroundInfo {
        ensureNotificationChannel()
        val launchIntent =
            applicationContext.packageManager
                .getLaunchIntentForPackage(applicationContext.packageName)
        val pendingIntent = launchIntent?.let {
            PendingIntent.getActivity(
                applicationContext,
                4092,
                it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        val notification =
            NotificationCompat.Builder(applicationContext, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_upload)
                .setContentTitle("Backup do TCloud em andamento")
                .setContentText("$total arquivo(s) aguardando sincronizacao.")
                .setOnlyAlertOnce(true)
                .setOngoing(true)
                .setCategory(NotificationCompat.CATEGORY_PROGRESS)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setProgress(total.coerceAtLeast(1), 0, total <= 0)
                .setContentIntent(pendingIntent)
                .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ForegroundInfo(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    private fun enqueueContinuation(delayMs: Long) {
        val prefs =
            applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val wifiOnly = prefs.getBoolean(KEY_WIFI_ONLY, false)
        val chargingOnly = prefs.getBoolean(KEY_REQUIRES_CHARGING, false)
        val constraints =
            Constraints.Builder()
                .setRequiredNetworkType(
                    if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED
                )
                .setRequiresCharging(chargingOnly)
                .setRequiresBatteryNotLow(true)
                .setRequiresStorageNotLow(true)
                .build()
        val request =
            OneTimeWorkRequestBuilder<TCloudGalleryWorker>()
                .setConstraints(constraints)
                .setInitialDelay(
                    delayMs.coerceAtLeast(10_000L),
                    TimeUnit.MILLISECONDS
                )
                .setBackoffCriteria(
                    BackoffPolicy.LINEAR,
                    30,
                    TimeUnit.SECONDS
                )
                .addTag("tcloud_gallery_continuation")
                .build()
        WorkManager.getInstance(applicationContext).enqueueUniqueWork(
            CONTINUATION_NAME,
            ExistingWorkPolicy.REPLACE,
            request
        )
    }
}
