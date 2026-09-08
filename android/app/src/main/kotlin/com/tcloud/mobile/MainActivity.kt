package com.tcloud.mobile
import android.content.res.Configuration
import android.os.Bundle
import android.util.Log
import android.util.Rational
import android.app.PictureInPictureParams
import android.view.WindowManager
import kotlin.concurrent.thread
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.net.Socket
import java.net.ServerSocket
import java.net.InetAddress
import java.io.RandomAccessFile
import java.security.MessageDigest
import android.provider.Settings

import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import android.app.NotificationManager
import android.app.NotificationChannel
import android.app.Activity
import android.Manifest
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.graphics.Bitmap
import android.content.ContentUris
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.MediaStore
import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.ExistingWorkPolicy
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.work.WorkManager
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.NetworkType
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.Constraints
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import java.io.File
import java.util.concurrent.TimeUnit
import java.lang.reflect.Array as ReflectArray
import java.lang.reflect.Field
import java.lang.reflect.Modifier

class MainActivity : FlutterActivity() {
    // TCLOUD_REALTIME_BACKGROUND_BACKUP_1050
    private var tcloudMediaObserver: ContentObserver? = null
    private var tcloudRealtimeLastEnqueueMs: Long = 0L
    // TCLOUD_NATIVE_THEME_SPLASH_1038
    override fun onCreate(savedInstanceState: Bundle?) {
        val prefs = getSharedPreferences("FlutterSharedPreferences", MODE_PRIVATE)
        val savedMode = prefs.getString("flutter.tcloud_theme_mode_v2", "system") ?: "system"

        val useDark = when (savedMode.lowercase()) {
            "dark", "escuro" -> true
            "light", "claro" -> false
            else -> {
                val nightMask =
                    resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
                nightMask == Configuration.UI_MODE_NIGHT_YES
            }
        }

        setTheme(
            if (useDark) R.style.TCloudLaunchThemeDark
            else R.style.TCloudLaunchThemeLight
        )

        super.onCreate(savedInstanceState)

        if (prefs.getBoolean("flutter.tcloud_secure_screen_v1", false)) {
            window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
        }

        // TCLOUD_REALTIME_BACKGROUND_BACKUP_1050
        registerTCloudMediaObserver()
        enqueueTCloudRealtimeBackup("startup")
        if (TCloudBackupService.isEnabled(applicationContext)) {
            try {
                TCloudBackupService.start(applicationContext)
            } catch (error: Throwable) {
                Log.w("TCloudBackup", "Nao foi possivel restaurar o servico", error)
            }
        }
    }

    override fun onDestroy() {
        tcloudMediaObserver?.let {
            try {
                contentResolver.unregisterContentObserver(it)
            } catch (_: Throwable) {
            }
        }
        tcloudMediaObserver = null
        super.onDestroy()
    }

    private data class TCloudVideoStreamItem(
        val fileId: Int,
        val size: Long,
        val mimeType: String,
        val sessionId: Long
    )

    private val tcloudVideoStreams =
        ConcurrentHashMap<Long, TCloudVideoStreamItem>()

    private val tcloudVideoLocks =
        ConcurrentHashMap<Int, Any>()

    @Volatile
    private var tcloudVideoServer:
        ServerSocket? = null

    @Volatile
    private var tcloudVideoPort:
        Int = 0


    companion object {
        private const val UPDATE_CHANNEL =
            "com.tcloud.mobile/updater"
        private const val METHOD_CHANNEL =
            "com.tcloud.mobile/tdlib"

        private const val EVENT_CHANNEL =
            "com.tcloud.mobile/tdlib_events"
    }
    private var tdClient: Client?
        get() = TCloudTdlibRuntime.client
        set(value) {
            TCloudTdlibRuntime.client = value
        }

    private var eventSink:
        EventChannel.EventSink? = null

    private var apiId: Int
        get() = TCloudTdlibRuntime.apiId
        set(value) {
            TCloudTdlibRuntime.apiId = value
        }

    private var apiHash: String
        get() = TCloudTdlibRuntime.apiHash
        set(value) {
            TCloudTdlibRuntime.apiHash = value
        }

    private var currentState: String
        get() = TCloudTdlibRuntime.state
        set(value) {
            TCloudTdlibRuntime.state = value
        }

    private var pendingFilePickerResult:
        MethodChannel.Result? = null

    private val filePickerRequestCode =
        9042

    private val mediaPermissionRequestCode =
        9043

    private var pendingMediaPermissionResult:
        MethodChannel.Result? = null

    private val pendingSharedFiles =
        mutableListOf<String>()

    override fun configureFlutterEngine(
        flutterEngine: FlutterEngine
    ) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            UPDATE_CHANNEL
        ).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "getAppInfo" -> {
                        result.success(
                            readTCloudAppInfo()
                        )
                    }

                    "getUpdateDownloadPath" -> {
                        val directory =
                            File(
                                cacheDir,
                                "updates"
                            )

                        if (!directory.exists()) {
                            directory.mkdirs()
                        }

                        result.success(
                            File(
                                directory,
                                "tcloud-mobile-update.apk"
                            ).absolutePath
                        )
                    }

                    "canInstallPackages" -> {
                        result.success(
                            canInstallTCloudPackages()
                        )
                    }

                    "openInstallPermission" -> {
                        openTCloudInstallPermission()
                        result.success(true)
                    }

                    "sha256" -> {
                        val path =
                            call.argument<String>(
                                "path"
                            ).orEmpty()

                        result.success(
                            tcloudSha256(path)
                        )
                    }

                    "installApk" -> {
                        val path =
                            call.argument<String>(
                                "path"
                            ).orEmpty()

                        installTCloudApk(path)
                        result.success(true)
                    }

                    
                    "ensureUpdateNotificationPermission" -> {
                        result.success(
                            TCloudUpdateNotifications
                                .ensurePermission(this)
                        )
                    }

                    "showUpdateDownloadProgress" -> {
                        val version =
                            call.argument<String>(
                                "version"
                            ).orEmpty()

                        val received =
                            call.argument<Number>(
                                "received"
                            )?.toLong() ?: 0L

                        val total =
                            call.argument<Number>(
                                "total"
                            )?.toLong() ?: 0L

                        TCloudUpdateNotifications
                            .showProgress(
                                this,
                                version,
                                received,
                                total
                            )

                        result.success(true)
                    }

                    "showUpdateReadyNotification" -> {
                        val version =
                            call.argument<String>(
                                "version"
                            ).orEmpty()

                        val path =
                            call.argument<String>(
                                "path"
                            ).orEmpty()

                        TCloudUpdateNotifications
                            .showReady(
                                this,
                                version,
                                path
                            )

                        result.success(true)
                    }

                    "showUpdateFailedNotification" -> {
                        val version =
                            call.argument<String>(
                                "version"
                            ).orEmpty()

                        val message =
                            call.argument<String>(
                                "message"
                            ).orEmpty()

                        TCloudUpdateNotifications
                            .showFailed(
                                this,
                                version,
                                message
                            )

                        result.success(true)
                    }


                    "startNativeUpdateDownload" -> {
                        val url =
                            call.argument<String>(
                                "url"
                            ).orEmpty()

                        val version =
                            call.argument<String>(
                                "version"
                            ).orEmpty()

                        val sha256 =
                            call.argument<String>(
                                "sha256"
                            ).orEmpty()

                        TCloudUpdateDownloadService
                            .start(
                                this,
                                url,
                                version,
                                sha256
                            )

                        result.success(true)
                    }

                    "getNativeUpdateDownloadStatus" -> {
                        result.success(
                            TCloudUpdateDownloadService
                                .status(this)
                        )
                    }

else -> result.notImplemented()
                }
            } catch (error: Throwable) {
                result.error(
                    "TCLOUD_UPDATE",
                    error.message
                        ?: error.toString(),
                    null
                )
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(
            object :
                EventChannel.StreamHandler {

                override fun onListen(
                    arguments: Any?,
                    events:
                        EventChannel.EventSink?
                ) {
                    eventSink = events
                    emitState(currentState)
                }

                override fun onCancel(
                    arguments: Any?
                ) {
                    eventSink = null
                }
            }
        )

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler {
                call,
                result ->

            when (call.method) {

                "getBackgroundBackupStatus" -> {
                    val powerManager = getSystemService(PowerManager::class.java)
                    val unrestricted =
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.M ||
                            powerManager.isIgnoringBatteryOptimizations(packageName)
                    result.success(
                        mapOf(
                            "enabled" to TCloudBackupService.isEnabled(applicationContext),
                            "batteryUnrestricted" to unrestricted
                        )
                    )
                }

                "requestIgnoreBatteryOptimizations" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val powerManager = getSystemService(PowerManager::class.java)
                            if (!powerManager.isIgnoringBatteryOptimizations(packageName)) {
                                startActivity(
                                    Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                                        data = Uri.parse("package:$packageName")
                                    }
                                )
                            }
                        }
                        result.success(true)
                    } catch (error: Throwable) {
                        result.error("BATTERY_OPTIMIZATION", error.message, null)
                    }
                }

                "setSecureScreen" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: false
                    if (enabled) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    }
                    result.success(true)
                }

                "enterPictureInPicture" -> {
                    try {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            val width = call.argument<Number>("width")?.toInt() ?: 16
                            val height = call.argument<Number>("height")?.toInt() ?: 9
                            val params = PictureInPictureParams.Builder()
                                .setAspectRatio(
                                    Rational(width.coerceAtLeast(1), height.coerceAtLeast(1))
                                )
                                .build()
                            result.success(enterPictureInPictureMode(params))
                        } else {
                            result.success(false)
                        }
                    } catch (error: Throwable) {
                        result.error("PICTURE_IN_PICTURE", error.message, null)
                    }
                }

                "prepareVideoStream" -> {
                    try {
                        val fileId =
                            call.argument<Number>(
                                "fileId"
                            )?.toInt() ?: 0

                        val hintedSize =
                            call.argument<Number>(
                                "size"
                            )?.toLong() ?: 0L

                        val mimeType =
                            call.argument<String>(
                                "mimeType"
                            )?.trim()
                                .orEmpty()
                                .ifBlank {
                                    "video/mp4"
                                }

                        if (fileId <= 0) {
                            result.error(
                                "VIDEO_STREAM",
                                "fileId invalido.",
                                null
                            )
                        } else {
                            result.success(
                                prepareTCloudVideoStream(
                                    fileId,
                                    hintedSize,
                                    mimeType
                                )
                            )
                        }
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "VIDEO_STREAM",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }


                "initialize" -> {
                    val receivedApiId =
                        call.argument<Number>(
                            "apiId"
                        )?.toInt() ?: 0

                    val receivedApiHash =
                        call.argument<String>(
                            "apiHash"
                        )?.trim().orEmpty()

                    if (
                        receivedApiId <= 0 ||
                        receivedApiHash.isBlank()
                    ) {
                        result.error(
                            "TCLOUD_CONFIG",
                            "API ID / API Hash do Telegram não configurados.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    apiId = receivedApiId
                    apiHash = receivedApiHash
                    TCloudTdlibRuntime.configure(
                        applicationContext,
                        receivedApiId,
                        receivedApiHash
                    )

                    try {
                        initializeTdlib()
                        result.success(true)
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "TDLIB_INIT",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "submitPhone" -> {
                    val phone =
                        call.argument<String>(
                            "phone"
                        )?.trim().orEmpty()

                    if (phone.isBlank()) {
                        result.error(
                            "PHONE",
                            "Número de telefone vazio.",
                            null
                        )
                    } else {
                        sendFireAndForget(
                            TdApi
                                .SetAuthenticationPhoneNumber(
                                    phone,
                                    null
                                )
                        )
                        result.success(true)
                    }
                }

                "submitCode" -> {
                    val code =
                        call.argument<String>(
                            "code"
                        )?.trim().orEmpty()

                    if (code.isBlank()) {
                        result.error(
                            "CODE",
                            "Código vazio.",
                            null
                        )
                    } else {
                        sendFireAndForget(
                            TdApi
                                .CheckAuthenticationCode(
                                    code
                                )
                        )
                        result.success(true)
                    }
                }

                "submitPassword" -> {
                    val password =
                        call.argument<String>(
                            "password"
                        ).orEmpty()

                    if (password.isEmpty()) {
                        result.error(
                            "PASSWORD",
                            "Senha vazia.",
                            null
                        )
                    } else {
                        sendFireAndForget(
                            TdApi
                                .CheckAuthenticationPassword(
                                    password
                                )
                        )
                        result.success(true)
                    }
                }

                "logout" -> {
                    sendFireAndForget(
                        TdApi.LogOut()
                    )
                    result.success(true)
                }

                "getState" -> {
                    result.success(
                        currentState
                    )
                }

                "shareFile" -> {
                    val path =
                        call.argument<String>(
                            "path"
                        ).orEmpty()

                    val mimeType =
                        call.argument<String>(
                            "mimeType"
                        )?.trim()
                            .orEmpty()
                            .ifBlank { "*/*" }

                    try {
                        shareLocalFile(
                            path,
                            mimeType
                        )
                        result.success(true)
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "SHARE_FILE",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "setBackgroundGalleryTarget" -> {
                    val chatId =
                        call.argument<Number>(
                            "chatId"
                        )?.toLong() ?: 0L

                    val threadId =
                        call.argument<Number>(
                            "messageThreadId"
                        )?.toLong() ?: 0L

                    if (chatId == 0L) {
                        result.error(
                            "BACKGROUND_TARGET",
                            "Destino de backup invalido.",
                            null
                        )
                    } else {
                        TCloudTdlibRuntime
                            .saveBackgroundTarget(
                                applicationContext,
                                chatId,
                                threadId
                            )

                        result.success(true)
                    }
                }
                "configureBackgroundGalleryOptions" -> {
                    val wifiOnly =
                        call.argument<Boolean>(
                            "wifiOnly"
                        ) ?: false

                    val requiresCharging =
                        call.argument<Boolean>(
                            "requiresCharging"
                        ) ?: false

                    getSharedPreferences(
                        TCloudGalleryWorker.PREFS,
                        MODE_PRIVATE
                    ).edit()
                        .putBoolean(
                            TCloudGalleryWorker
                                .KEY_WIFI_ONLY,
                            wifiOnly
                        )
                        .putBoolean(
                            TCloudGalleryWorker
                                .KEY_REQUIRES_CHARGING,
                            requiresCharging
                        )
                        .apply()

                    configureBackgroundGallerySync(
                        true
                    )

                    result.success(true)
                }
                "requestBackupNotifications" -> {
                    try {
                        ensureBackupNotificationChannel()

                        if (
                            android.os.Build.VERSION.SDK_INT >=
                                android.os.Build.VERSION_CODES.TIRAMISU &&
                            ActivityCompat.checkSelfPermission(
                                this,
                                Manifest.permission.POST_NOTIFICATIONS
                            ) != PackageManager.PERMISSION_GRANTED
                        ) {
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.POST_NOTIFICATIONS
                                ),
                                1409
                            )
                        }

                        result.success(true)
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "NOTIFICATION_PERMISSION",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }
                "scheduleBackgroundGallerySync" -> {
                    try {
                        val enabled =
                            call.argument<Boolean>(
                                "enabled"
                            ) ?: true

                        configureBackgroundGallerySync(
                            enabled
                        )

                        result.success(true)
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "BACKGROUND_SYNC",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "getBackgroundGalleryQueue" -> {
                    try {
                        result.success(
                            readBackgroundGalleryQueue()
                        )
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "BACKGROUND_QUEUE",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "ackBackgroundGalleryQueue" -> {
                    val uris =
                        call.argument<List<String>>(
                            "uris"
                        ) ?: emptyList()

                    try {
                        acknowledgeBackgroundGalleryQueue(
                            uris
                        )
                        result.success(true)
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "BACKGROUND_QUEUE_ACK",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "setBackgroundGalleryAlbumTargets" -> {
                    @Suppress("UNCHECKED_CAST")
                    val raw = call.argument<Map<String, Any?>>("targets") ?: emptyMap()
                    val clean = linkedMapOf<String, Long>()
                    for ((key, value) in raw) {
                        val id = when (value) {
                            is Number -> value.toLong()
                            else -> value?.toString()?.toLongOrNull() ?: 0L
                        }
                        if (key.isNotBlank() && id != 0L) clean[key] = id
                    }
                    TCloudTdlibRuntime.saveBackgroundAlbumTargets(this, clean)
                    result.success(true)
                }

                "getBackgroundBackupRecords" -> {
                    result.success(TCloudTdlibRuntime.backgroundBackupRecords(this))
                }
                "forgetBackgroundBackupUris" -> {
                    val uris = call.argument<List<String>>("uris")
                        ?.filter { it.isNotBlank() }
                        ?.toSet()
                        ?: emptySet()
                    TCloudTdlibRuntime.forgetBackgroundBackupUris(this, uris)
                    result.success(true)
                }
                "setBackgroundHiddenAlbums" -> {
                    val albums =
                        call.argument<List<String>>("albums")
                            ?.map { it.trim().lowercase() }
                            ?.filter { it.isNotBlank() }
                            ?.toSet()
                            ?: emptySet()
                    getSharedPreferences(
                        TCloudGalleryWorker.PREFS,
                        MODE_PRIVATE
                    ).edit()
                        .putStringSet(
                            TCloudGalleryWorker.KEY_HIDDEN_ALBUMS,
                            albums
                        )
                        .apply()
                    result.success(true)
                }
                // TCLOUD_GALLERY_NOTIFICATION_NATIVE_1052
                "showGallerySyncProgress" -> {
                    val total =
                        call.argument<Number>("total")?.toInt() ?: 0
                    val done =
                        call.argument<Number>("done")?.toInt() ?: 0
                    val failed =
                        call.argument<Number>("failed")?.toInt() ?: 0
                    val running =
                        call.argument<Boolean>("running") ?: false

                    showGallerySyncProgressNotification(
                        total = total,
                        done = done,
                        failed = failed,
                        running = running
                    )
                    result.success(true)
                }

                "clearBackgroundBackupRecords" -> {
                    TCloudTdlibRuntime.clearBackgroundBackupRecords(this)
                    result.success(true)
                }

                "getTCloudCacheInfo" -> {
                    result.success(tcloudCacheInfo())
                }

                "clearTCloudTemporaryCache" -> {
                    clearTCloudTemporaryCache()
                    result.success(tcloudCacheInfo())
                }

                "generateVideoThumbnail" -> {
                    val path =
                        call.argument<String>(
                            "path"
                        ).orEmpty()

                    try {
                        result.success(
                            generateVideoThumbnail(
                                path
                            )
                        )
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "VIDEO_THUMBNAIL",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }
                "requestMediaPermission" -> {
                    requestMediaPermission(
                        result
                    )
                }

                "listGalleryMedia" -> {
                    val sinceMs =
                        call.argument<Number>(
                            "sinceMs"
                        )?.toLong() ?: 0L

                    val limit =
                        call.argument<Number>(
                            "limit"
                        )?.toInt() ?: 500

                    try {
                        result.success(
                            listGalleryMedia(
                                sinceMs,
                                limit
                            )
                        )
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "GALLERY_QUERY",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }


                "listGalleryMediaBefore" -> {
                    val beforeMs =
                        call.argument<Number>(
                            "beforeMs"
                        )?.toLong()
                            ?: Long.MAX_VALUE

                    val limit =
                        call.argument<Int>(
                            "limit"
                        ) ?: 80

                    try {
                        result.success(
                            listGalleryMediaBefore(
                                beforeMs,
                                limit
                            )
                        )
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "GALLERY_QUERY_PAGE",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "copyContentUri" -> {
                    val raw =
                        call.argument<String>(
                            "uri"
                        ).orEmpty()

                    try {
                        val path =
                            copyUriToLocalFile(
                                Uri.parse(raw)
                            )

                        result.success(path)
                    } catch (
                        error: Throwable
                    ) {
                        result.error(
                            "GALLERY_COPY",
                            error.message
                                ?: error.toString(),
                            null
                        )
                    }
                }

                "getPendingSharedFiles" -> {
                    val values =
                        synchronized(
                            pendingSharedFiles
                        ) {
                            val copy =
                                pendingSharedFiles
                                    .toList()

                            pendingSharedFiles
                                .clear()

                            copy
                        }

                    result.success(values)
                }

                "pickFiles" -> {
                    if (
                        pendingFilePickerResult != null
                    ) {
                        result.error(
                            "PICKER_BUSY",
                            "O seletor de arquivos já está aberto.",
                            null
                        )
                        return@setMethodCallHandler
                    }

                    pendingFilePickerResult =
                        result

                    val intent =
                        Intent(
                            Intent.ACTION_OPEN_DOCUMENT
                        ).apply {
                            type = "*/*"

                            addCategory(
                                Intent.CATEGORY_OPENABLE
                            )

                            putExtra(
                                Intent.EXTRA_ALLOW_MULTIPLE,
                                true
                            )
                        }

                    startActivityForResult(
                        intent,
                        filePickerRequestCode
                    )
                }


                "sendDocument" -> {
                    val chatId =
                        call.argument<Number>(
                            "chatId"
                        )?.toLong() ?: 0L

                    val forumTopicId =
                        call.argument<Number>(
                            "forumTopicId"
                        )?.toInt() ?: 0

                    val threadId =
                        call.argument<Number>(
                            "messageThreadId"
                        )?.toLong() ?: 0L

                    val path =
                        call.argument<String>(
                            "path"
                        )?.trim().orEmpty()

                    sendDocumentDirect(
                        chatId,
                        forumTopicId,
                        threadId,
                        path,
                        result
                    )
                }

                "execute" -> {
                    val functionName =
                        call.argument<String>(
                            "function"
                        ).orEmpty()

                    @Suppress("UNCHECKED_CAST")
                    val fields =
                        call.argument<Map<String, Any?>>(
                            "fields"
                        ) ?: emptyMap()

                    executeGeneric(
                        functionName,
                        fields,
                        result
                    )
                }

                else ->
                    result.notImplemented()
            }
        }

        collectSharedIntent(intent)
    }

    override fun onNewIntent(
        intent: Intent
    ) {
        super.onNewIntent(intent)
        setIntent(intent)
        collectSharedIntent(intent)
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?
    ) {
        if (
            requestCode ==
                filePickerRequestCode
        ) {
            val result =
                pendingFilePickerResult

            pendingFilePickerResult =
                null

            if (result == null) {
                return
            }

            if (
                resultCode !=
                    Activity.RESULT_OK ||
                data == null
            ) {
                result.success(
                    emptyList<String>()
                )
                return
            }

            try {
                val uris =
                    mutableListOf<Uri>()

                data.clipData?.let {
                        clip ->

                    for (
                        index in
                            0 until
                            clip.itemCount
                    ) {
                        uris.add(
                            clip
                                .getItemAt(
                                    index
                                )
                                .uri
                        )
                    }
                }

                data.data?.let {
                    uri ->

                    if (
                        uris.none {
                            it == uri
                        }
                    ) {
                        uris.add(uri)
                    }
                }

                val paths =
                    uris.map {
                        copyUriToLocalFile(it)
                    }

                result.success(paths)
            } catch (
                error: Throwable
            ) {
                result.error(
                    "PICKER_COPY",
                    error.message
                        ?: error.toString(),
                    null
                )
            }

            return
        }

        super.onActivityResult(
            requestCode,
            resultCode,
            data
        )
    }

    @Suppress("DEPRECATION")
    private fun readTCloudAppInfo():
        Map<String, Any> {
        val info =
            packageManager.getPackageInfo(
                packageName,
                0
            )

        val versionCode =
            if (
                Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.P
            ) {
                info.longVersionCode
            } else {
                info.versionCode.toLong()
            }

        return mapOf(
            "version" to
                (info.versionName ?: "0.0.0"),
            "versionCode" to versionCode,
            "canInstallPackages" to
                canInstallTCloudPackages()
        )
    }

    private fun canInstallTCloudPackages():
        Boolean {
        return if (
            Build.VERSION.SDK_INT >=
            Build.VERSION_CODES.O
        ) {
            packageManager
                .canRequestPackageInstalls()
        } else {
            true
        }
    }

    private fun openTCloudInstallPermission() {
        if (
            Build.VERSION.SDK_INT <
            Build.VERSION_CODES.O
        ) {
            return
        }

        val intent =
            Intent(
                Settings
                    .ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse(
                    "package:$packageName"
                )
            )

        startActivity(intent)
    }

    private fun validatedUpdateFile(
        path: String
    ): File {
        if (path.isBlank()) {
            throw IllegalArgumentException(
                "Caminho do APK vazio."
            )
        }

        val file = File(path)
        val allowedRoot =
            File(
                cacheDir,
                "updates"
            ).canonicalFile

        val actual = file.canonicalFile

        if (
            actual.parentFile != allowedRoot
        ) {
            throw SecurityException(
                "APK fora da pasta de atualizacao."
            )
        }

        if (
            !actual.exists() ||
            !actual.isFile
        ) {
            throw IllegalStateException(
                "APK de atualizacao nao encontrado."
            )
        }

        return actual
    }

    private fun tcloudSha256(
        path: String
    ): String {
        val file =
            validatedUpdateFile(path)

        val digest =
            MessageDigest.getInstance(
                "SHA-256"
            )

        file.inputStream()
            .buffered()
            .use { input ->
                val buffer =
                    ByteArray(1024 * 1024)

                while (true) {
                    val read =
                        input.read(buffer)

                    if (read <= 0) break

                    digest.update(
                        buffer,
                        0,
                        read
                    )
                }
            }

        return digest.digest()
            .joinToString("") {
                "%02x".format(
                    it.toInt() and 0xff
                )
            }
    }

    private fun installTCloudApk(
        path: String
    ) {
        if (
            !canInstallTCloudPackages()
        ) {
            throw SecurityException(
                "Autorize 'Permitir desta fonte' " +
                    "para o TCloud."
            )
        }

        val file =
            validatedUpdateFile(path)

        val uri =
            FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file
            )

        val intent =
            Intent(
                Intent.ACTION_VIEW
            ).apply {
                setDataAndType(
                    uri,
                    "application/vnd.android." +
                        "package-archive"
                )

                addFlags(
                    Intent
                        .FLAG_GRANT_READ_URI_PERMISSION
                )
            }

        startActivity(intent)
    }

    private fun prepareTCloudVideoStream(
        fileId: Int,
        hintedSize: Long,
        mimeType: String
    ): String {
        val file =
            getTCloudFileBlocking(
                fileId
            )

        val actualSize =
            when {
                file.size > 0L ->
                    file.size

                file.expectedSize > 0L ->
                    file.expectedSize

                hintedSize > 0L ->
                    hintedSize

                else ->
                    0L
            }

        if (actualSize <= 0L) {
            throw IllegalStateException(
                "Tamanho do video indisponivel."
            )
        }

        val sessionId =
            System.nanoTime()

        tcloudVideoStreams[sessionId] =
            TCloudVideoStreamItem(
                fileId = fileId,
                size = actualSize,
                mimeType =
                    mimeType.ifBlank {
                        "video/mp4"
                    },
                sessionId = sessionId
            )

        // Mantem sessoes simultaneas para itens que compartilham o mesmo
        // fileId. O limite evita crescimento indefinido durante a navegacao.
        if (tcloudVideoStreams.size > 64) {
            tcloudVideoStreams.keys
                .sorted()
                .take(tcloudVideoStreams.size - 48)
                .forEach { tcloudVideoStreams.remove(it) }
        }

        val port =
            ensureTCloudVideoServer()

        return "http://127.0.0.1:" +
            port +
            "/video/" +
            fileId +
            "?session=" +
            sessionId
    }

    @Synchronized
    private fun ensureTCloudVideoServer():
        Int {
        val existing =
            tcloudVideoServer

        if (
            existing != null &&
            !existing.isClosed &&
            tcloudVideoPort > 0
        ) {
            return tcloudVideoPort
        }

        val server =
            ServerSocket(
                0,
                16,
                InetAddress.getByName(
                    "127.0.0.1"
                )
            )

        server.reuseAddress =
            true

        tcloudVideoServer =
            server

        tcloudVideoPort =
            server.localPort

        thread(
            start = true,
            isDaemon = true,
            name = "tcloud-video-server"
        ) {
            while (!server.isClosed) {
                try {
                    val socket =
                        server.accept()

                    thread(
                        start = true,
                        isDaemon = true,
                        name = "tcloud-video-client"
                    ) {
                        handleTCloudVideoSocket(
                            socket
                        )
                    }
                } catch (
                    _: Throwable
                ) {
                    if (!server.isClosed) {
                        try {
                            Thread.sleep(80)
                        } catch (
                            _: Throwable
                        ) {
                        }
                    }
                }
            }
        }

        return tcloudVideoPort
    }

    private fun handleTCloudVideoSocket(
        socket: Socket
    ) {
        socket.use {
            try {
                socket.tcpNoDelay =
                    true

                socket.soTimeout =
                    30_000

                val reader =
                    socket
                        .getInputStream()
                        .bufferedReader(
                            Charsets.US_ASCII
                        )

                val requestLine =
                    reader.readLine()
                        ?: return

                val parts =
                    requestLine.split(" ")

                val method =
                    parts
                        .getOrNull(0)
                        .orEmpty()
                        .uppercase()

                val target =
                    parts
                        .getOrNull(1)
                        .orEmpty()

                val headers =
                    mutableMapOf<
                        String,
                        String
                    >()

                while (true) {
                    val line =
                        reader.readLine()
                            ?: break

                    if (line.isEmpty()) {
                        break
                    }

                    val colon =
                        line.indexOf(':')

                    if (colon > 0) {
                        headers[
                            line.substring(
                                0,
                                colon
                            )
                                .trim()
                                .lowercase()
                        ] =
                            line.substring(
                                colon + 1
                            ).trim()
                    }
                }

                val fileId =
                    target
                        .substringBefore('?')
                        .substringAfterLast('/')
                        .toIntOrNull()

                val sessionId =
                    target
                        .substringAfter(
                            "session=",
                            ""
                        )
                        .substringBefore("&")
                        .toLongOrNull()

                val item =
                    if (sessionId == null) {
                        null
                    } else {
                        tcloudVideoStreams[
                            sessionId
                        ]
                    }

                if (
                    fileId == null ||
                    item == null ||
                    item.fileId != fileId ||
                    sessionId == null ||
                    item.sessionId != sessionId
                ) {
                    writeTCloudHttpError(
                        socket,
                        404,
                        "Not Found"
                    )

                    return
                }

                if (
                    method != "GET" &&
                    method != "HEAD"
                ) {
                    writeTCloudHttpError(
                        socket,
                        405,
                        "Method Not Allowed"
                    )

                    return
                }

                val rangeHeader =
                    headers["range"]

                val range =
                    if (rangeHeader == null) {
                        0L to
                            (item.size - 1L)
                    } else {
                        parseTCloudRange(
                            rangeHeader,
                            item.size
                        )
                    }

                if (range == null) {
                    val output =
                        socket.getOutputStream()

                    val response =
                        "HTTP/1.1 416 Range Not Satisfiable\r\n" +
                            "Content-Range: bytes */" +
                            item.size +
                            "\r\n" +
                            "Connection: close\r\n" +
                            "\r\n"

                    output.write(
                        response.toByteArray(
                            Charsets.US_ASCII
                        )
                    )

                    output.flush()
                    return
                }

                val start =
                    range.first

                val end =
                    range.second

                val length =
                    end - start + 1L

                val output =
                    socket.getOutputStream()

                val partial =
                    rangeHeader != null

                val status =
                    if (partial) {
                        "206 Partial Content"
                    } else {
                        "200 OK"
                    }

                val response =
                    StringBuilder()
                        .append("HTTP/1.1 ")
                        .append(status)
                        .append("\r\n")
                        .append(
                            "Accept-Ranges: bytes\r\n"
                        )
                        .append(
                            "Content-Type: "
                        )
                        .append(item.mimeType)
                        .append("\r\n")
                        .append(
                            "Content-Length: "
                        )
                        .append(length)
                        .append("\r\n")
                        .append(
                            "Cache-Control: no-store\r\n"
                        )
                        .apply {
                            if (partial) {
                                append(
                                    "Content-Range: bytes "
                                )
                                append(start)
                                append("-")
                                append(end)
                                append("/")
                                append(item.size)
                                append("\r\n")
                            }
                        }
                        .append(
                            "Connection: close\r\n"
                        )
                        .append("\r\n")
                        .toString()

                output.write(
                    response.toByteArray(
                        Charsets.US_ASCII
                    )
                )

                output.flush()

                if (method == "HEAD") {
                    return
                }

                var position =
                    start

                var firstChunk =
                    true

                while (position <= end) {
                    val latest =
                        tcloudVideoStreams[item.sessionId]

                    if (
                        latest == null ||
                        latest.sessionId != item.sessionId
                    ) {
                        return
                    }

                    val desired =
                        if (firstChunk) {
                            256L * 1024L
                        } else {
                            2L * 1024L * 1024L
                        }

                    val chunkSize =
                        minOf(
                            desired,
                            end - position + 1L
                        )

                    val local =
                        downloadTCloudVideoRange(
                            fileId,
                            position,
                            chunkSize
                        )

                    RandomAccessFile(
                        local,
                        "r"
                    ).use {
                        random ->
                        random.seek(
                            position
                        )

                        var remaining =
                            chunkSize

                        val buffer =
                            ByteArray(
                                128 * 1024
                            )

                        while (remaining > 0L) {
                            val wanted =
                                minOf(
                                    buffer.size.toLong(),
                                    remaining
                                ).toInt()

                            val read =
                                random.read(
                                    buffer,
                                    0,
                                    wanted
                                )

                            if (read <= 0) {
                                throw IllegalStateException(
                                    "Cache TDLib terminou antes do range esperado."
                                )
                            }

                            output.write(
                                buffer,
                                0,
                                read
                            )

                            remaining -=
                                read.toLong()
                        }
                    }

                    output.flush()

                    position +=
                        chunkSize

                    firstChunk =
                        false
                }
            } catch (
                error: Throwable
            ) {
                Log.w(
                    "TCLOUD_MEDIA",
                    "stream request failed: ${error.message}",
                    error
                )
            }
        }
    }

    private fun parseTCloudRange(
        header: String,
        total: Long
    ): Pair<Long, Long>? {
        if (
            !header.startsWith(
                "bytes=",
                ignoreCase = true
            )
        ) {
            return null
        }

        val raw =
            header
                .substringAfter("=")
                .substringBefore(",")
                .trim()

        val dash =
            raw.indexOf('-')

        if (dash < 0) {
            return null
        }

        val left =
            raw.substring(
                0,
                dash
            ).trim()

        val right =
            raw.substring(
                dash + 1
            ).trim()

        if (left.isEmpty()) {
            val suffix =
                right.toLongOrNull()
                    ?: return null

            if (suffix <= 0L) {
                return null
            }

            val start =
                maxOf(
                    0L,
                    total - suffix
                )

            return start to
                (total - 1L)
        }

        val start =
            left.toLongOrNull()
                ?: return null

        if (
            start < 0L ||
            start >= total
        ) {
            return null
        }

        val requestedEnd =
            if (right.isEmpty()) {
                total - 1L
            } else {
                right.toLongOrNull()
                    ?: return null
            }

        val end =
            minOf(
                requestedEnd,
                total - 1L
            )

        if (end < start) {
            return null
        }

        return start to end
    }

    private fun getTCloudFileBlocking(
        fileId: Int
    ): TdApi.File {
        val current =
            tdClient
                ?: throw IllegalStateException(
                    "TDLib ainda nao foi inicializado."
                )

        val latch =
            CountDownLatch(1)

        var file:
            TdApi.File? = null

        var error:
            String? = null

        current.send(
            TdApi.GetFile(
                fileId
            )
        ) {
                response ->
            when (response) {
                is TdApi.File ->
                    file = response

                is TdApi.Error ->
                    error =
                        "${response.code}: ${response.message}"

                else ->
                    error =
                        "Resposta inesperada de GetFile."
            }

            latch.countDown()
        }

        if (
            !latch.await(
                30,
                TimeUnit.SECONDS
            )
        ) {
            throw IllegalStateException(
                "Timeout em GetFile."
            )
        }

        if (error != null) {
            throw IllegalStateException(
                error
            )
        }

        return file
            ?: throw IllegalStateException(
                "GetFile nao retornou arquivo."
            )
    }

    private fun downloadTCloudVideoRange(
        fileId: Int,
        offset: Long,
        limit: Long
    ): File {
        val lock =
            tcloudVideoLocks
                .getOrPut(
                    fileId
                ) {
                    Any()
                }

        synchronized(lock) {
            val current =
                tdClient
                    ?: throw IllegalStateException(
                        "TDLib ainda nao foi inicializado."
                    )

            val latch =
                CountDownLatch(1)

            var downloaded:
                TdApi.File? = null

            var error:
                String? = null

            current.send(
                TdApi.DownloadFile(
                    fileId,
                    32,
                    offset,
                    limit,
                    true
                )
            ) {
                    response ->
                when (response) {
                    is TdApi.File ->
                        downloaded = response

                    is TdApi.Error ->
                        error =
                            "${response.code}: ${response.message}"

                    else ->
                        error =
                            "Resposta inesperada de DownloadFile."
                }

                latch.countDown()
            }

            if (
                !latch.await(
                    45,
                    TimeUnit.SECONDS
                )
            ) {
                throw IllegalStateException(
                    "Timeout ao baixar trecho do video."
                )
            }

            if (error != null) {
                throw IllegalStateException(
                    error
                )
            }

            val result =
                downloaded
                    ?: throw IllegalStateException(
                        "TDLib nao retornou o arquivo."
                    )

            val path =
                result.local.path
                    ?.trim()
                    .orEmpty()

            if (path.isEmpty()) {
                throw IllegalStateException(
                    "TDLib nao informou caminho do cache."
                )
            }

            val prefixLatch =
                CountDownLatch(1)

            var prefix =
                0L

            var prefixError:
                String? = null

            current.send(
                TdApi.GetFileDownloadedPrefixSize(
                    fileId,
                    offset
                )
            ) {
                    response ->
                when (response) {
                    is TdApi.FileDownloadedPrefixSize ->
                        prefix = response.size

                    is TdApi.Error ->
                        prefixError =
                            "${response.code}: ${response.message}"

                    else ->
                        prefixError =
                            "Resposta inesperada de GetFileDownloadedPrefixSize."
                }

                prefixLatch.countDown()
            }

            if (
                !prefixLatch.await(
                    30,
                    TimeUnit.SECONDS
                )
            ) {
                throw IllegalStateException(
                    "Timeout ao verificar trecho do video."
                )
            }

            if (prefixError != null) {
                throw IllegalStateException(
                    prefixError
                )
            }

            if (prefix < limit) {
                Log.w(
                    "TCLOUD_MEDIA",
                    "short TDLib range fileId=$fileId offset=$offset " +
                        "requested=$limit prefix=$prefix"
                )

                throw IllegalStateException(
                    "TDLib retornou range incompleto."
                )
            }

            val file =
                File(path)

            if (!file.exists()) {
                throw IllegalStateException(
                    "Arquivo parcial do TDLib nao existe."
                )
            }

            return file
        }
    }

    private fun writeTCloudHttpError(
        socket: Socket,
        code: Int,
        reason: String
    ) {
        try {
            val body =
                "$code $reason"

            val bytes =
                body.toByteArray(
                    Charsets.UTF_8
                )

            val response =
                "HTTP/1.1 " +
                    code +
                    " " +
                    reason +
                    "\r\n" +
                    "Content-Type: text/plain\r\n" +
                    "Content-Length: " +
                    bytes.size +
                    "\r\n" +
                    "Connection: close\r\n" +
                    "\r\n"

            socket.getOutputStream()
                .apply {
                    write(
                        response.toByteArray(
                            Charsets.US_ASCII
                        )
                    )
                    write(bytes)
                    flush()
                }
        } catch (
            _: Throwable
        ) {
        }
    }

    private fun shareLocalFile(
        path: String,
        mimeType: String
    ) {
        if (path.isBlank()) {
            throw IllegalArgumentException(
                "Caminho do arquivo vazio."
            )
        }

        val file = File(path)

        if (!file.exists()) {
            throw IllegalStateException(
                "Arquivo local nÃ£o encontrado."
            )
        }

        val uri =
            FileProvider.getUriForFile(
                this,
                "${applicationContext.packageName}.fileprovider",
                file
            )

        val intent =
            Intent(
                Intent.ACTION_SEND
            ).apply {
                type = mimeType
                putExtra(
                    Intent.EXTRA_STREAM,
                    uri
                )
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            }

        startActivity(
            Intent.createChooser(
                intent,
                "Compartilhar arquivo"
            )
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (
            requestCode ==
                mediaPermissionRequestCode
        ) {
            val pending =
                pendingMediaPermissionResult

            pendingMediaPermissionResult =
                null

            val granted =
                grantResults.isNotEmpty() &&
                    grantResults.all {
                        it ==
                            PackageManager
                                .PERMISSION_GRANTED
                    }

            pending?.success(granted)
            return
        }

        super.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults
        )
    }

    private fun requestMediaPermission(
        result: MethodChannel.Result
    ) {
        if (hasMediaPermission()) {
            result.success(true)
            return
        }

        if (
            pendingMediaPermissionResult !=
                null
        ) {
            result.error(
                "MEDIA_PERMISSION_BUSY",
                "A solicitacao de permissao ja esta aberta.",
                null
            )
            return
        }

        pendingMediaPermissionResult =
            result

        val permissions =
            if (
                Build.VERSION.SDK_INT >=
                    Build.VERSION_CODES.TIRAMISU
            ) {
                arrayOf(
                    Manifest.permission
                        .READ_MEDIA_IMAGES,
                    Manifest.permission
                        .READ_MEDIA_VIDEO
                )
            } else {
                arrayOf(
                    Manifest.permission
                        .READ_EXTERNAL_STORAGE
                )
            }

        ActivityCompat.requestPermissions(
            this,
            permissions,
            mediaPermissionRequestCode
        )
    }

    private fun hasMediaPermission(): Boolean {
        if (
            Build.VERSION.SDK_INT >=
                Build.VERSION_CODES.TIRAMISU
        ) {
            return ContextCompat
                .checkSelfPermission(
                    this,
                    Manifest.permission
                        .READ_MEDIA_IMAGES
                ) ==
                PackageManager
                    .PERMISSION_GRANTED &&
                ContextCompat
                    .checkSelfPermission(
                        this,
                        Manifest.permission
                            .READ_MEDIA_VIDEO
                    ) ==
                PackageManager
                    .PERMISSION_GRANTED
        }

        return ContextCompat
            .checkSelfPermission(
                this,
                Manifest.permission
                    .READ_EXTERNAL_STORAGE
            ) ==
            PackageManager
                .PERMISSION_GRANTED
    }


    private fun listGalleryMediaBefore(
        beforeMs: Long,
        requestedLimit: Int
    ): List<Map<String, Any?>> {
        if (!hasMediaPermission()) {
            throw SecurityException(
                "Permissao para fotos e videos nao concedida."
            )
        }

        if (android.os.Build.VERSION.SDK_INT >= 34) {
            val fullImages =
                androidx.core.app.ActivityCompat.checkSelfPermission(
                    this,
                    android.Manifest.permission.READ_MEDIA_IMAGES
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED

            val fullVideos =
                androidx.core.app.ActivityCompat.checkSelfPermission(
                    this,
                    android.Manifest.permission.READ_MEDIA_VIDEO
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED

            val selectedOnly =
                androidx.core.app.ActivityCompat.checkSelfPermission(
                    this,
                    android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED
                ) == android.content.pm.PackageManager.PERMISSION_GRANTED

            if (selectedOnly && (!fullImages || !fullVideos)) {
                throw SecurityException(
                    "O TCloud tem acesso somente a fotos selecionadas. " +
                        "Nas configuracoes do Android, abra TCloud > Fotos e videos " +
                        "e escolha Permitir tudo."
                )
            }
        }

        val limit = requestedLimit.coerceIn(1, 250)
        val collection = MediaStore.Files.getContentUri("external")
        val bucketColumn =
            MediaStore.Images.ImageColumns.BUCKET_DISPLAY_NAME
        val pathColumn =
            if (android.os.Build.VERSION.SDK_INT >=
                android.os.Build.VERSION_CODES.Q
            ) {
                MediaStore.MediaColumns.RELATIVE_PATH
            } else {
                MediaStore.MediaColumns.DATA
            }

        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_ADDED,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            bucketColumn,
            pathColumn
        )

        val beforeSeconds =
            if (beforeMs <= 0L || beforeMs == Long.MAX_VALUE) {
                Long.MAX_VALUE
            } else {
                (beforeMs / 1000L).coerceAtLeast(1L)
            }

        val selection =
            "(" + MediaStore.Files.FileColumns.MEDIA_TYPE + "=? OR " +
                MediaStore.Files.FileColumns.MEDIA_TYPE + "=?) AND " +
                MediaStore.Files.FileColumns.DATE_ADDED + "<?"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            beforeSeconds.toString()
        )

        val genericAlbums = setOf(
            "", "outros", "other", "others", "galeria", "gallery",
            "pictures", "picture", "images", "image", "media", "android",
            "dcim", "download", "downloads", "movies", "videos", "video"
        )

        fun generic(value: String): Boolean =
            value.trim().lowercase() in genericAlbums

        fun packageLike(value: String): Boolean =
            Regex(
                "^[a-z0-9_]+(?:\\.[a-z0-9_]+){1,}$",
                RegexOption.IGNORE_CASE
            ).matches(value.trim())

        fun albumFrom(relativePath: String, bucket: String): String {
            val parts = relativePath
                .replace('\\', '/')
                .split('/')
                .map { it.trim() }
                .filter { it.isNotBlank() && !it.startsWith(".") }

            for (part in parts.asReversed()) {
                if (!generic(part) && !packageLike(part)) {
                    return part
                }
            }

            if (bucket.isNotBlank() && !generic(bucket)) {
                return bucket.trim()
            }

            return "Outros"
        }

        val result = mutableListOf<Map<String, Any?>>()

        contentResolver.query(
            collection,
            projection,
            selection,
            args,
            MediaStore.Files.FileColumns.DATE_ADDED + " DESC"
        )?.use { cursor ->
            val idIndex = cursor.getColumnIndexOrThrow(
                MediaStore.Files.FileColumns._ID
            )
            val nameIndex = cursor.getColumnIndexOrThrow(
                MediaStore.Files.FileColumns.DISPLAY_NAME
            )
            val mimeIndex = cursor.getColumnIndexOrThrow(
                MediaStore.Files.FileColumns.MIME_TYPE
            )
            val sizeIndex = cursor.getColumnIndexOrThrow(
                MediaStore.Files.FileColumns.SIZE
            )
            val dateIndex = cursor.getColumnIndexOrThrow(
                MediaStore.Files.FileColumns.DATE_ADDED
            )
            val mediaIndex = cursor.getColumnIndexOrThrow(
                MediaStore.Files.FileColumns.MEDIA_TYPE
            )
            val bucketIndex = cursor.getColumnIndex(bucketColumn)
            val pathIndex = cursor.getColumnIndex(pathColumn)

            while (cursor.moveToNext() && result.size < limit) {
                val id = cursor.getLong(idIndex)
                val uri = ContentUris.withAppendedId(collection, id)
                val mediaType = cursor.getInt(mediaIndex)
                val bucket =
                    if (bucketIndex >= 0) {
                        cursor.getString(bucketIndex).orEmpty()
                    } else {
                        ""
                    }
                val rawPath =
                    if (pathIndex >= 0) {
                        cursor.getString(pathIndex).orEmpty()
                    } else {
                        ""
                    }
                val relativePath =
                    if (android.os.Build.VERSION.SDK_INT >=
                        android.os.Build.VERSION_CODES.Q
                    ) {
                        rawPath
                    } else {
                        java.io.File(rawPath).parent.orEmpty()
                    }
                val album = albumFrom(relativePath, bucket)

                result.add(
                    mapOf(
                        "uri" to uri.toString(),
                        "name" to cursor.getString(nameIndex),
                        "mime" to cursor.getString(mimeIndex),
                        "size" to cursor.getLong(sizeIndex),
                        "dateMs" to cursor.getLong(dateIndex) * 1000L,
                        "kind" to if (
                            mediaType ==
                                MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                        ) "video" else "image",
                        "album" to album,
                        "bucketName" to bucket,
                        "relativePath" to relativePath
                    )
                )
            }
        }

        return result
    }

private fun listGalleryMedia(
        sinceMs: Long,
        requestedLimit: Int
    ): List<Map<String, Any?>> {
        if (!hasMediaPermission()) {
            throw SecurityException(
                "Permissao para fotos e videos nao concedida."
            )
        }

        val limit = requestedLimit.coerceIn(1, 1000)
        val collection = MediaStore.Files.getContentUri("external")
        val columns = mutableListOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.DATE_ADDED,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            columns.add(MediaStore.Files.FileColumns.RELATIVE_PATH)
        }

        val sinceSeconds = (sinceMs / 1000L).coerceAtLeast(0L)
        val selection =
            "(" + MediaStore.Files.FileColumns.MEDIA_TYPE + "=? OR " +
            MediaStore.Files.FileColumns.MEDIA_TYPE + "=?) AND " +
            MediaStore.Files.FileColumns.DATE_ADDED + ">=?"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            sinceSeconds.toString()
        )
        val result = mutableListOf<Map<String, Any?>>()

        contentResolver.query(
            collection,
            columns.toTypedArray(),
            selection,
            args,
            MediaStore.Files.FileColumns.DATE_ADDED + " DESC"
        )?.use { cursor ->
            val idI = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameI = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val mimeI = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
            val sizeI = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val dateI = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_ADDED)
            val mediaI = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val bucketI = cursor.getColumnIndex(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME)
            val relativeI =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q)
                    cursor.getColumnIndex(MediaStore.Files.FileColumns.RELATIVE_PATH)
                else -1

            while (cursor.moveToNext() && result.size < limit) {
                val id = cursor.getLong(idI)
                val relativePath =
                    if (relativeI >= 0) cursor.getString(relativeI).orEmpty() else ""
                val bucket =
                    if (bucketI >= 0) cursor.getString(bucketI).orEmpty() else ""
                val album =
                    bucket.trim().ifEmpty {
                        relativePath.trim('/').split('/').lastOrNull().orEmpty()
                    }.ifEmpty { "Galeria" }
                val mediaType = cursor.getInt(mediaI)

                result.add(
                    mapOf(
                        "uri" to ContentUris.withAppendedId(collection, id).toString(),
                        "name" to cursor.getString(nameI),
                        "mime" to cursor.getString(mimeI),
                        "size" to cursor.getLong(sizeI),
                        "dateMs" to cursor.getLong(dateI) * 1000L,
                        "kind" to if (
                            mediaType == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                        ) "video" else "image",
                        "album" to album,
                        "relativePath" to relativePath
                    )
                )
            }
        }
        return result
    }

    private fun collectSharedIntent(
        sharedIntent: Intent?
    ) {
        if (sharedIntent == null) {
            return
        }

        val action =
            sharedIntent.action

        if (
            action !=
                Intent.ACTION_SEND &&
            action !=
                Intent.ACTION_SEND_MULTIPLE
        ) {
            return
        }

        val uris =
            mutableListOf<Uri>()

        if (
            action ==
                Intent.ACTION_SEND
        ) {
            val uri =
                if (
                    Build.VERSION.SDK_INT >=
                        Build.VERSION_CODES.TIRAMISU
                ) {
                    sharedIntent
                        .getParcelableExtra(
                            Intent.EXTRA_STREAM,
                            Uri::class.java
                        )
                } else {
                    @Suppress(
                        "DEPRECATION"
                    )
                    sharedIntent
                        .getParcelableExtra<Uri>(
                            Intent.EXTRA_STREAM
                        )
                }

            if (uri != null) {
                uris.add(uri)
            }
        } else {
            val values =
                if (
                    Build.VERSION.SDK_INT >=
                        Build.VERSION_CODES.TIRAMISU
                ) {
                    sharedIntent
                        .getParcelableArrayListExtra(
                            Intent.EXTRA_STREAM,
                            Uri::class.java
                        )
                } else {
                    @Suppress(
                        "DEPRECATION"
                    )
                    sharedIntent
                        .getParcelableArrayListExtra<Uri>(
                            Intent.EXTRA_STREAM
                        )
                }

            if (values != null) {
                uris.addAll(values)
            }
        }

        if (uris.isEmpty()) {
            return
        }

        val paths =
            mutableListOf<String>()

        for (uri in uris) {
            try {
                paths.add(
                    copyUriToLocalFile(uri)
                )
            } catch (
                _: Throwable
            ) {
            }
        }

        if (paths.isNotEmpty()) {
            synchronized(
                pendingSharedFiles
            ) {
                pendingSharedFiles
                    .addAll(paths)
            }
        }

        // Avoid processing the same startup intent on every resume.
        sharedIntent.action = null
    }

    // TCLOUD_REALTIME_BACKGROUND_BACKUP_1050
    // Detecta inclusoes/alteracoes no MediaStore enquanto o processo do TCloud
    // esta vivo, inclusive quando a Activity esta em segundo plano.
    // O WorkManager periodico existente continua como fallback persistente.
    private fun registerTCloudMediaObserver() {
        if (tcloudMediaObserver != null) {
            return
        }

        val observer =
            object : ContentObserver(Handler(Looper.getMainLooper())) {
                override fun onChange(selfChange: Boolean) {
                    super.onChange(selfChange)
                    enqueueTCloudRealtimeBackup("media-change")
                }

                override fun onChange(
                    selfChange: Boolean,
                    uri: Uri?
                ) {
                    super.onChange(selfChange, uri)
                    enqueueTCloudRealtimeBackup("media-change-uri")
                }
            }

        try {
            contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                observer
            )
            contentResolver.registerContentObserver(
                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                true,
                observer
            )
            tcloudMediaObserver = observer
        } catch (_: Throwable) {
            // O WorkManager periodico permanece como fallback.
        }
    }

    private fun enqueueTCloudRealtimeBackup(reason: String) {
        val preferences =
            getSharedPreferences(
                TCloudGalleryWorker.PREFS,
                MODE_PRIVATE
            )

        if (!preferences.getBoolean(TCloudGalleryWorker.KEY_ENABLED, false)) {
            return
        }

        val now = System.currentTimeMillis()

        // MediaStore costuma emitir mais de um evento para a mesma captura.
        // Debounce curto evita criar varios workers para uma unica foto/video.
        if (now - tcloudRealtimeLastEnqueueMs < 1500L) {
            return
        }

        tcloudRealtimeLastEnqueueMs = now

        val wifiOnly =
            preferences.getBoolean(
                TCloudGalleryWorker.KEY_WIFI_ONLY,
                false
            )

        val requiresCharging =
            preferences.getBoolean(
                TCloudGalleryWorker.KEY_REQUIRES_CHARGING,
                false
            )

        val constraints =
            Constraints.Builder()
                .setRequiredNetworkType(
                    if (wifiOnly) {
                        NetworkType.UNMETERED
                    } else {
                        NetworkType.CONNECTED
                    }
                )
                .setRequiresCharging(requiresCharging)
                .build()

        val request =
            OneTimeWorkRequestBuilder<TCloudGalleryWorker>()
                .setConstraints(constraints)
                .setInitialDelay(2, TimeUnit.SECONDS)
                .addTag("tcloud_gallery_realtime")
                .build()

        WorkManager.getInstance(applicationContext)
            .enqueueUniqueWork(
                "tcloud_gallery_realtime_v1",
                // Nunca cancela um upload que ja esta em andamento. Eventos
                // novos entram no fim da cadeia e rodam assim que ele terminar.
                ExistingWorkPolicy.APPEND_OR_REPLACE,
                request
            )

        Log.d(
            "TCloudBackup",
            "Realtime backup enqueued: $reason"
        )
    }
    // TCLOUD_GALLERY_NOTIFICATION_NATIVE_1052
    private fun showGallerySyncProgressNotification(
        total: Int,
        done: Int,
        failed: Int,
        running: Boolean
    ) {
        try {
            ensureBackupNotificationChannel()

            val safeTotal = total.coerceAtLeast(0)
            val safeDone = done.coerceIn(0, if (safeTotal > 0) safeTotal else done.coerceAtLeast(0))
            val percent =
                if (safeTotal > 0) {
                    ((safeDone.toDouble() / safeTotal.toDouble()) * 100.0)
                        .toInt()
                        .coerceIn(0, 100)
                } else {
                    0
                }

            val text =
                when {
                    running && safeTotal > 0 ->
                        "$safeDone de $safeTotal sincronizados"
                    running ->
                        "Sincronizando arquivos..."
                    failed > 0 ->
                        "Concluido com $failed falha(s)"
                    safeTotal > 0 ->
                        "$safeDone de $safeTotal sincronizados"
                    else ->
                        "Sincronizacao em dia"
                }

            val builder =
                NotificationCompat.Builder(
                    this,
                    "tcloud_backup"
                )
                    .setSmallIcon(R.mipmap.ic_launcher)
                    .setContentTitle("TCloud - Sincronizacao")
                    .setContentText(text)
                    .setOnlyAlertOnce(true)
                    .setOngoing(running)
                    .setAutoCancel(!running)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .setCategory(NotificationCompat.CATEGORY_PROGRESS)

            if (running) {
                builder.setProgress(
                    if (safeTotal > 0) safeTotal else 100,
                    if (safeTotal > 0) safeDone else 0,
                    safeTotal <= 0
                )
            } else {
                builder.setProgress(0, 0, false)
            }

            NotificationManagerCompat
                .from(this)
                .notify(10520, builder.build())
        } catch (_: SecurityException) {
            // Android 13+ pode estar sem permissao de notificacao.
        } catch (_: Throwable) {
            // Progresso visual nunca deve interromper a sincronizacao.
        }
    }
    private fun ensureBackupNotificationChannel() {
        if (
            android.os.Build.VERSION.SDK_INT <
                android.os.Build.VERSION_CODES.O
        ) {
            return
        }

        val manager =
            getSystemService(
                NotificationManager::class.java
            )

        val channel =
            NotificationChannel(
                "tcloud_backup",
                "Backup do TCloud",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description =
                    "Status do backup automatico de fotos e videos."
            }

        manager.createNotificationChannel(
            channel
        )
    }
    private fun configureBackgroundGallerySync(
        enabled: Boolean
    ) {
        getSharedPreferences(
            TCloudGalleryWorker.PREFS,
            MODE_PRIVATE
        ).edit()
            .putBoolean(
                TCloudGalleryWorker.KEY_ENABLED,
                enabled
            )
            .apply()

        val manager =
            WorkManager.getInstance(
                applicationContext
            )

        if (!enabled) {
            TCloudBackupService.stop(applicationContext)
            manager.cancelUniqueWork(
                TCloudGalleryWorker.UNIQUE_NAME
            )
            manager.cancelUniqueWork(
                "tcloud_gallery_realtime_v1"
            )
            manager.cancelUniqueWork(
                TCloudGalleryWorker.CONTINUATION_NAME
            )
            return
        }

        // TCLOUD_REALTIME_BACKGROUND_BACKUP_1050
        // Ao ativar o backup, nao espera o primeiro ciclo periodico.
        enqueueTCloudRealtimeBackup("enabled")
        try {
            TCloudBackupService.start(applicationContext)
        } catch (error: Throwable) {
            Log.w("TCloudBackup", "Nao foi possivel iniciar o servico", error)
        }

        val preferences =
            getSharedPreferences(
                TCloudGalleryWorker.PREFS,
                MODE_PRIVATE
            )

        val wifiOnly =
            preferences.getBoolean(
                TCloudGalleryWorker.KEY_WIFI_ONLY,
                false
            )

        val requiresCharging =
            preferences.getBoolean(
                TCloudGalleryWorker.KEY_REQUIRES_CHARGING,
                false
            )

        val constraints =
            Constraints.Builder()
                .setRequiredNetworkType(
                    if (wifiOnly) {
                        NetworkType.UNMETERED
                    } else {
                        NetworkType.CONNECTED
                    }
                )
                .setRequiresCharging(
                    requiresCharging
                )
                .setRequiresBatteryNotLow(true)
                .setRequiresStorageNotLow(true)
                .build()

        val request =
            PeriodicWorkRequestBuilder<
                TCloudGalleryWorker
            >(
                15,
                TimeUnit.MINUTES
            )
                .setConstraints(constraints)
                .build()

        manager.enqueueUniquePeriodicWork(
            TCloudGalleryWorker.UNIQUE_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            request
        )
    }

    private fun readBackgroundGalleryQueue():
        List<Map<String, Any?>> {
        val file =
            File(
                filesDir,
                TCloudGalleryWorker.QUEUE_FILE
            )

        if (!file.exists()) {
            return emptyList()
        }

        val array = TCloudBackgroundQueueStore.read(applicationContext)

        val result =
            mutableListOf<
                Map<String, Any?>
            >()

        for (index in 0 until array.length()) {
            val item =
                array.optJSONObject(index)
                    ?: continue

            result.add(
                mapOf(
                    "uri" to item.optString("uri"),
                    "name" to item.optString("name"),
                    "mime" to item.optString("mime"),
                    "size" to item.optLong("size"),
                    "dateMs" to item.optLong("dateMs"),
                    "kind" to item.optString("kind"),
                    "attempts" to item.optInt("attempts")
                )
            )
        }

        return result
    }

    private fun acknowledgeBackgroundGalleryQueue(
        completedUris: List<String>
    ) {
        if (completedUris.isEmpty()) {
            return
        }

        val completed =
            completedUris.toSet()

        val file =
            File(
                filesDir,
                TCloudGalleryWorker.QUEUE_FILE
            )

        if (!file.exists()) {
            return
        }

        TCloudBackgroundQueueStore.removeUris(applicationContext, completed)
    }

    private fun generateVideoThumbnail(
        path: String
    ): String? {
        if (path.isBlank()) {
            return null
        }

        val source =
            File(path)

        if (!source.exists()) {
            return null
        }

        val outputDir =
            File(
                cacheDir,
                "tcloud_video_thumbnails"
            )

        outputDir.mkdirs()

        val output =
            File(
                outputDir,
                source.absolutePath.hashCode()
                    .toString() +
                    "_" +
                    source.length()
                        .toString() +
                    "_" +
                    source.lastModified()
                        .toString() +
                    ".jpg"
            )

        if (
            output.exists() &&
            output.length() > 0L
        ) {
            return output.absolutePath
        }

        val retriever =
            MediaMetadataRetriever()

        try {
            retriever.setDataSource(
                source.absolutePath
            )

            val bitmap =
                if (
                    android.os.Build.VERSION.SDK_INT >=
                        android.os.Build.VERSION_CODES.O_MR1
                ) {
                    retriever.getScaledFrameAtTime(
                        1_000_000L,
                        MediaMetadataRetriever
                            .OPTION_CLOSEST_SYNC,
                        480,
                        480
                    )
                } else {
                    retriever.getFrameAtTime(
                        1_000_000L,
                        MediaMetadataRetriever
                            .OPTION_CLOSEST_SYNC
                    )
                }

            if (bitmap == null) {
                return null
            }

            output.outputStream().use {
                    stream ->
                bitmap.compress(
                    Bitmap.CompressFormat.JPEG,
                    82,
                    stream
                )
            }

            bitmap.recycle()

            return output.absolutePath
        } finally {
            retriever.release()
        }
    }
    private fun copyUriToLocalFile(
        uri: Uri
    ): String {
        var name =
            "arquivo_${System.currentTimeMillis()}"

        contentResolver.query(
            uri,
            null,
            null,
            null,
            null
        )?.use {
                cursor ->

            val index =
                cursor.getColumnIndex(
                    OpenableColumns.DISPLAY_NAME
                )

            if (
                index >= 0 &&
                cursor.moveToFirst()
            ) {
                val candidate =
                    cursor.getString(index)

                if (
                    !candidate.isNullOrBlank()
                ) {
                    name = candidate
                }
            }
        }

        val safeName =
            name.replace(
                Regex("[\\\\/:*?\"<>|]"),
                "_"
            )

        val uploadDir =
            File(
                cacheDir,
                "tcloud_uploads"
            )

        uploadDir.mkdirs()

        val itemDir = File(
            uploadDir,
            "${System.currentTimeMillis()}_${System.nanoTime()}"
        )
        itemDir.mkdirs()
        val destination = File(itemDir, safeName)

        contentResolver
            .openInputStream(uri)
            ?.use {
                input ->

                destination
                    .outputStream()
                    .use {
                        output ->

                        input.copyTo(
                            output
                        )
                    }
            }
            ?: throw IllegalStateException(
                "Não foi possível abrir o arquivo selecionado."
            )

        return destination.absolutePath
    }

    private fun tcloudCacheDirectories(): List<File> =
        listOf(
            File(cacheDir, "tcloud_uploads"),
            File(cacheDir, "tcloud_background_uploads"),
            File(cacheDir, "tcloud_video_thumbnails")
        )

    private fun tcloudDirectoryBytes(file: File): Long {
        if (!file.exists()) return 0L
        if (file.isFile) return file.length()
        var total = 0L
        file.listFiles()?.forEach { total += tcloudDirectoryBytes(it) }
        return total
    }

    private fun tcloudCacheInfo(): Map<String, Any> {
        var total = 0L
        for (dir in tcloudCacheDirectories()) total += tcloudDirectoryBytes(dir)
        return mapOf(
            "bytes" to total,
            "megabytes" to total.toDouble() / (1024.0 * 1024.0)
        )
    }

    private fun clearTCloudTemporaryCache() {
        for (dir in tcloudCacheDirectories()) {
            try {
                if (dir.exists()) dir.deleteRecursively()
                dir.mkdirs()
            } catch (_: Throwable) {}
        }
    }

    private fun initializeTdlib() {
        if (tdClient != null) {
            emitState(currentState)
            return
        }

        currentState = "initializing"
        emitState(currentState)

        Client.setLogMessageHandler(
            2
        ) { verbosityLevel, message ->
            if (verbosityLevel <= 2) {
                android.util.Log.d(
                    "TCloud-TDLib",
                    message
                )
            }
        }

        tdClient = Client.create(
            { update ->
                handleTdlibUpdate(update)
            },
            { error ->
                emitError(
                    "TDLib update handler: " +
                        (error.message
                            ?: error.toString())
                )
            },
            { error ->
                emitError(
                    "TDLib request handler: " +
                        (error.message
                            ?: error.toString())
                )
            }
        )
    }

    private fun handleTdlibUpdate(
        update: TdApi.Object
    ) {
        TCloudTdlibRuntime.handleMessageSendUpdate(update)

        if (
            update is
                TdApi.UpdateAuthorizationState
        ) {
            handleAuthorizationState(
                update.authorizationState
            )
        }
    }

    private fun handleAuthorizationState(
        state:
            TdApi.AuthorizationState
    ) {
        when (state.constructor) {

            TdApi
                .AuthorizationStateWaitTdlibParameters
                .CONSTRUCTOR -> {

                currentState =
                    "initializing"

                emitState(
                    currentState
                )

                val databaseDir =
                    File(
                        filesDir,
                        "tdlib/database"
                    )

                val tdFilesDir =
                    File(
                        filesDir,
                        "tdlib/files"
                    )

                databaseDir.mkdirs()
                tdFilesDir.mkdirs()

                val parameters =
                    TdApi.SetTdlibParameters()

                parameters.databaseDirectory =
                    databaseDir.absolutePath

                parameters.filesDirectory =
                    tdFilesDir.absolutePath

                parameters.useMessageDatabase =
                    true

                parameters.useSecretChats =
                    false

                parameters.apiId =
                    apiId

                parameters.apiHash =
                    apiHash

                parameters.systemLanguageCode =
                    "pt-BR"

                parameters.deviceModel =
                    "${Build.MANUFACTURER} ${Build.MODEL}"

                parameters.applicationVersion =
                    "0.2"

                sendFireAndForget(
                    parameters
                )
            }

            TdApi
                .AuthorizationStateWaitPhoneNumber
                .CONSTRUCTOR -> {
                currentState = "phone"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateWaitCode
                .CONSTRUCTOR -> {
                currentState = "code"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateWaitPassword
                .CONSTRUCTOR -> {
                currentState =
                    "password"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateWaitEmailAddress
                .CONSTRUCTOR -> {
                currentState =
                    "email_address"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateWaitEmailCode
                .CONSTRUCTOR -> {
                currentState =
                    "email_code"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateWaitRegistration
                .CONSTRUCTOR -> {
                currentState =
                    "registration"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateWaitOtherDeviceConfirmation
                .CONSTRUCTOR -> {
                currentState =
                    "other_device"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateReady
                .CONSTRUCTOR -> {
                currentState = "ready"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateLoggingOut
                .CONSTRUCTOR -> {
                currentState =
                    "logging_out"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateClosing
                .CONSTRUCTOR -> {
                currentState =
                    "closing"
                emitState(currentState)
            }

            TdApi
                .AuthorizationStateClosed
                .CONSTRUCTOR -> {
                currentState =
                    "closed"
                emitState(currentState)
                tdClient = null
            }

            else -> {
                currentState =
                    "authorization"
                emitState(currentState)
            }
        }
    }



    private fun sendDocumentDirect(
        chatId: Long,
        forumTopicId: Int,
        threadId: Long,
        path: String,
        result: MethodChannel.Result
    ) {
        val current = tdClient

        if (current == null) {
            result.error(
                "TDLIB_NOT_READY",
                "TDLib ainda nao foi inicializado.",
                null
            )
            return
        }

        if (currentState != "ready") {
            result.error(
                "TDLIB_AUTH",
                "Telegram ainda nao esta autenticado.",
                currentState
            )
            return
        }

        if (chatId == 0L) {
            result.error(
                "UPLOAD_DESTINATION",
                "Destino de upload invalido.",
                null
            )
            return
        }

        val source = File(path)

        if (
            path.isBlank() ||
            !source.exists() ||
            !source.isFile
        ) {
            result.error(
                "UPLOAD_FILE",
                "Arquivo local nao encontrado.",
                path
            )
            return
        }

        try {
            val inputFile =
                TdApi.InputFileLocal().apply {
                    this.path =
                        source.absolutePath
                }

            val inputDocument =
                TdApi.InputDocument().apply {
                    document = inputFile
                    thumbnail = null
                    disableContentTypeDetection =
                        false
                }

            val caption =
                TdApi.FormattedText().apply {
                    text = ""
                    entities =
                        emptyArray<TdApi.TextEntity>()
                }

            val content =
                TdApi.InputMessageDocument().apply {
                    document = inputDocument
                    this.caption = caption
                }

            val topic:
                TdApi.MessageTopic? =
                when {
                    forumTopicId != 0 ->
                        TdApi.MessageTopicForum().apply {
                            this.forumTopicId =
                                forumTopicId
                        }

                    threadId != 0L ->
                        TdApi.MessageTopicThread().apply {
                            messageThreadId =
                                threadId
                        }

                    else -> null
                }

            val request =
                TdApi.SendMessage().apply {
                    this.chatId = chatId
                    topicId = topic
                    replyTo = null
                    options = null
                    replyMarkup = null
                    inputMessageContent =
                        content
                }

            current.send(request) {
                    response ->

                runOnUiThread {
                    when (response) {
                        is TdApi.Message -> {
                            thread(
                                start = true,
                                isDaemon = true,
                                name = "tcloud-send-confirmation"
                            ) {
                                val finalId =
                                    TCloudTdlibRuntime.awaitFinalMessageId(response)
                                runOnUiThread {
                                    if (finalId != 0L) {
                                        result.success(finalId)
                                    } else {
                                        result.error(
                                            "TDLIB_SEND_DOCUMENT",
                                            "O Telegram nao confirmou o envio do arquivo.",
                                            null
                                        )
                                    }
                                }
                            }
                        }

                        is TdApi.Error ->
                            result.error(
                                "TDLIB_SEND_DOCUMENT",
                                "${response.code}: ${response.message}",
                                null
                            )

                        else ->
                            result.error(
                                "TDLIB_SEND_DOCUMENT",
                                "Resposta inesperada do Telegram: $response",
                                null
                            )
                    }
                }
            }
        } catch (
            error: Throwable
        ) {
            result.error(
                "TDLIB_SEND_DOCUMENT",
                error.message
                    ?: error.toString(),
                null
            )
        }
    }

private fun buildVideoContent(
        source: File,
        caption: TdApi.FormattedText
    ): TdApi.InputMessageVideo {
        var durationSeconds = 0
        var width = 0
        var height = 0

        val retriever =
            MediaMetadataRetriever()

        try {
            retriever.setDataSource(
                source.absolutePath
            )

            durationSeconds =
                (
                    retriever.extractMetadata(
                        MediaMetadataRetriever
                            .METADATA_KEY_DURATION
                    )?.toLongOrNull()
                        ?: 0L
                )
                    .div(1000L)
                    .toInt()

            width =
                retriever.extractMetadata(
                    MediaMetadataRetriever
                        .METADATA_KEY_VIDEO_WIDTH
                )?.toIntOrNull() ?: 0

            height =
                retriever.extractMetadata(
                    MediaMetadataRetriever
                        .METADATA_KEY_VIDEO_HEIGHT
                )?.toIntOrNull() ?: 0

            val rotation =
                retriever.extractMetadata(
                    MediaMetadataRetriever
                        .METADATA_KEY_VIDEO_ROTATION
                )?.toIntOrNull() ?: 0

            if (
                rotation == 90 ||
                rotation == 270
            ) {
                val tmp = width
                width = height
                height = tmp
            }
        } catch (
            _: Throwable
        ) {
        } finally {
            try {
                retriever.release()
            } catch (
                _: Throwable
            ) {
            }
        }

        val inputFile =
            TdApi.InputFileLocal().apply {
                path =
                    source.absolutePath
            }

        val inputVideo =
            TdApi.InputVideo().apply {
                video = inputFile
                thumbnail = null
                cover = null
                startTimestamp = 0
                addedStickerFileIds =
                    intArrayOf()
                duration =
                    durationSeconds
                this.width =
                    width
                this.height =
                    height
                supportsStreaming =
                    true
            }

        return TdApi.InputMessageVideo().apply {
            video = inputVideo
            this.caption = caption
            showCaptionAboveMedia =
                false
            selfDestructType =
                null
            hasSpoiler =
                false
        }
    }
    private fun executeGeneric(
        functionName: String,
        fields: Map<String, Any?>,
        result:
            MethodChannel.Result
    ) {
        val client = tdClient

        if (client == null) {
            result.error(
                "TDLIB_NOT_READY",
                "TDLib ainda não foi inicializado.",
                null
            )
            return
        }

        if (currentState != "ready") {
            result.error(
                "TDLIB_AUTH",
                "Telegram ainda não está autenticado.",
                currentState
            )
            return
        }

        try {
            val function =
                createTdObject(
                    functionName,
                    fields
                )

            if (
                function !is
                    TdApi.Function<*>
            ) {
                result.error(
                    "TDLIB_FUNCTION",
                    "$functionName não é uma função TDLib.",
                    null
                )
                return
            }

            client.send(function) {
                    response ->

                val mapped =
                    tdValueToFlutter(
                        response,
                        0
                    )

                runOnUiThread {
                    result.success(
                        mapped
                    )
                }
            }
        } catch (
            error: Throwable
        ) {
            result.error(
                "TDLIB_EXECUTE",
                error.message
                    ?: error.toString(),
                null
            )
        }
    }

    private fun createTdObject(
        typeName: String,
        values:
            Map<String, Any?>
    ): Any {
        val clazz =
            Class.forName(
                "org.drinkless.tdlib.TdApi\$$typeName"
            )

        val ctor =
            clazz.declaredConstructors
                .firstOrNull {
                    it.parameterCount == 0
                }
                ?: throw IllegalStateException(
                    "TDLib $typeName não possui construtor vazio."
                )

        ctor.isAccessible = true

        val instance =
            ctor.newInstance()

        for (
            (name, value) in values
        ) {
            val field =
                findField(
                    clazz,
                    name
                )
                    ?: continue

            field.isAccessible = true

            val converted =
                convertValue(
                    field.type,
                    value
                )

            field.set(
                instance,
                converted
            )
        }

        return instance
    }

    private fun findField(
        clazz: Class<*>,
        name: String
    ): Field? {
        var current: Class<*>? = clazz

        while (current != null) {
            val concrete: Class<*> = current

            try {
                return concrete.getDeclaredField(name)
            } catch (_: NoSuchFieldException) {
                current = concrete.superclass
            }
        }

        return null
    }

    private fun convertValue(
        target: Class<*>,
        value: Any?
    ): Any? {
        if (value == null) {
            return null
        }

        if (
            target == Int::class.javaPrimitiveType ||
            target == Int::class.java
        ) {
            return (
                value as Number
            ).toInt()
        }

        if (
            target == Long::class.javaPrimitiveType ||
            target == Long::class.java
        ) {
            return (
                value as Number
            ).toLong()
        }

        if (
            target == Double::class.javaPrimitiveType ||
            target == Double::class.java
        ) {
            return (
                value as Number
            ).toDouble()
        }

        if (
            target == Boolean::class.javaPrimitiveType ||
            target == Boolean::class.java
        ) {
            return value as Boolean
        }

        if (target == String::class.java) {
            return value.toString()
        }

        if (
            target.isArray &&
            value is List<*>
        ) {
            val component =
                target.componentType

            val array =
                ReflectArray.newInstance(
                    component,
                    value.size
                )

            value.forEachIndexed {
                    index,
                    entry ->

                ReflectArray.set(
                    array,
                    index,
                    convertValue(
                        component,
                        entry
                    )
                )
            }

            return array
        }

        if (value is Map<*, *>) {
            val typeName =
                value["_type"]
                    ?.toString()

            if (
                !typeName.isNullOrBlank()
            ) {
                @Suppress("UNCHECKED_CAST")
                val nested =
                    value.entries
                        .filter {
                            it.key
                                ?.toString() !=
                                "_type"
                        }
                        .associate {
                            it.key
                                .toString() to
                                it.value
                        }

                return createTdObject(
                    typeName,
                    nested
                )
            }
        }

        return value
    }

    private fun tdValueToFlutter(
        value: Any?,
        depth: Int
    ): Any? {
        if (value == null) {
            return null
        }

        if (depth > 8) {
            return null
        }

        when (value) {
            is String,
            is Boolean,
            is Int,
            is Long,
            is Double,
            is Float ->
                return value
        }

        val clazz =
            value.javaClass

        if (clazz.isArray) {
            val length =
                ReflectArray.getLength(
                    value
                )

            val list =
                mutableListOf<Any?>()

            for (
                index in 0 until length
            ) {
                list.add(
                    tdValueToFlutter(
                        ReflectArray.get(
                            value,
                            index
                        ),
                        depth + 1
                    )
                )
            }

            return list
        }

        if (
            value is Collection<*>
        ) {
            return value.map {
                tdValueToFlutter(
                    it,
                    depth + 1
                )
            }
        }

        if (
            value is TdApi.Object
        ) {
            val map =
                linkedMapOf<String, Any?>()

            map["_type"] =
                clazz.simpleName

            var current:
                Class<*>? = clazz

            while (
                current != null &&
                current != Any::class.java
            ) {
                for (
                    field in
                        current.declaredFields
                ) {
                    if (
                        Modifier.isStatic(
                            field.modifiers
                        )
                    ) {
                        continue
                    }

                    try {
                        field.isAccessible =
                            true

                        map[field.name] =
                            tdValueToFlutter(
                                field.get(
                                    value
                                ),
                                depth + 1
                            )
                    } catch (
                        _: Throwable
                    ) {}
                }

                current =
                    current.superclass
            }

            return map
        }

        return value.toString()
    }

    private fun sendFireAndForget(
        function:
            TdApi.Function<*>
    ) {
        val client = tdClient

        if (client == null) {
            emitError(
                "TDLib ainda não foi inicializado."
            )
            return
        }

        client.send(function) {
                response ->

            if (
                response is
                    TdApi.Error
            ) {
                emitError(
                    "${response.code}: ${response.message}"
                )
            }
        }
    }

    private fun emitState(
        state: String
    ) {
        runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "state",
                    "state" to state
                )
            )
        }
    }

    private fun emitError(
        message: String
    ) {
        runOnUiThread {
            eventSink?.success(
                mapOf(
                    "type" to "error",
                    "message" to message
                )
            )
        }
    }
}
