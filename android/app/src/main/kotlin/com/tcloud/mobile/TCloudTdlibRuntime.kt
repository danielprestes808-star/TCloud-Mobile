package com.tcloud.mobile

import android.content.Context
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import org.json.JSONArray

import org.json.JSONObject
import java.io.File
import java.lang.reflect.Array as ReflectArray
import java.lang.reflect.Field
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

object TCloudTdlibRuntime {
    private const val PREFS =
        "tcloud_tdlib_runtime"

    private const val KEY_API_ID =
        "api_id"

    private const val KEY_API_HASH =
        "api_hash"

    private const val TARGET_PREFS =
        "tcloud_background"

    private const val KEY_TARGET_CHAT_ID =
        "target_chat_id"

    private const val KEY_TARGET_THREAD_ID =
        "target_thread_id"

    private const val KEY_ALBUM_TARGETS =
        "gallery_album_targets_v1"

    private const val KEY_BACKUP_RECORDS =
        "gallery_backup_records_v1"

    @Volatile
    var client: Client? = null

    @Volatile
    var state: String =
        "uninitialized"

    @Volatile
    var apiId: Int = 0

    @Volatile
    var apiHash: String = ""

    @Volatile
    private var queueProcessing:
        Boolean = false

    @Volatile
    private var lastSendError: String = ""

    private class PendingMessageSend {
        val latch = CountDownLatch(1)
        @Volatile var finalMessageId: Long = 0L
    }

    private val pendingMessageSends =
        ConcurrentHashMap<Long, PendingMessageSend>()
    private val completedMessageSends =
        ConcurrentHashMap<Long, Long>()
    private val failedMessageSends =
        ConcurrentHashMap.newKeySet<Long>()

    fun handleMessageSendUpdate(update: TdApi.Object) {
        when (update) {
            is TdApi.UpdateMessageSendSucceeded -> {
                val pending = pendingMessageSends[update.oldMessageId]
                if (pending == null) {
                    completedMessageSends[update.oldMessageId] = update.message.id
                } else {
                    pending.finalMessageId = update.message.id
                    pending.latch.countDown()
                }
            }
            is TdApi.UpdateMessageSendFailed -> {
                val pending = pendingMessageSends[update.oldMessageId]
                if (pending == null) {
                    failedMessageSends.add(update.oldMessageId)
                } else {
                    pending.finalMessageId = 0L
                    pending.latch.countDown()
                }
            }
        }
    }

    fun awaitFinalMessageId(
        message: TdApi.Message,
        timeoutSeconds: Long = 540L
    ): Long {
        if (message.sendingState == null) return message.id
        if (message.sendingState is TdApi.MessageSendingStateFailed) return 0L

        val temporaryId = message.id
        val pending = PendingMessageSend()
        pendingMessageSends[temporaryId] = pending

        completedMessageSends.remove(temporaryId)?.let {
            pending.finalMessageId = it
            pending.latch.countDown()
        }
        if (failedMessageSends.remove(temporaryId)) {
            pending.finalMessageId = 0L
            pending.latch.countDown()
        }

        val completed = pending.latch.await(timeoutSeconds, TimeUnit.SECONDS)
        pendingMessageSends.remove(temporaryId, pending)
        return if (completed) pending.finalMessageId else 0L
    }

    @Synchronized
    fun configure(
        context: Context,
        id: Int,
        hash: String
    ) {
        apiId = id
        apiHash = hash

        context.getSharedPreferences(
            PREFS,
            Context.MODE_PRIVATE
        ).edit()
            .putInt(KEY_API_ID, id)
            .putString(KEY_API_HASH, hash)
            .apply()
    }

    fun saveBackgroundTarget(
        context: Context,
        chatId: Long,
        messageThreadId: Long
    ) {
        context.getSharedPreferences(
            TARGET_PREFS,
            Context.MODE_PRIVATE
        ).edit()
            .putLong(
                KEY_TARGET_CHAT_ID,
                chatId
            )
            .putLong(
                KEY_TARGET_THREAD_ID,
                messageThreadId
            )
            .apply()
    }

    fun saveBackgroundAlbumTargets(
        context: Context,
        targets: Map<String, Long>
    ) {
        val json = JSONObject()
        for ((album, threadId) in targets) {
            if (album.isNotBlank() && threadId != 0L) {
                json.put(album.trim().lowercase(), threadId)
            }
        }
        context.getSharedPreferences(TARGET_PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY_ALBUM_TARGETS, json.toString()).apply()
    }

    private fun loadBackgroundAlbumTargets(context: Context): Map<String, Long> {
        val raw = context.getSharedPreferences(TARGET_PREFS, Context.MODE_PRIVATE)
            .getString(KEY_ALBUM_TARGETS, null) ?: return emptyMap()
        return try {
            val json = JSONObject(raw)
            val out = linkedMapOf<String, Long>()
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val value = json.optLong(key, 0L)
                if (value != 0L) out[key] = value
            }
            out
        } catch (_: Throwable) {
            emptyMap()
        }
    }

    fun backgroundBackupRecords(context: Context): List<Map<String, Any?>> {
        val raw = context.getSharedPreferences(TARGET_PREFS, Context.MODE_PRIVATE)
            .getString(KEY_BACKUP_RECORDS, null) ?: return emptyList()
        return try {
            val array = JSONArray(raw)
            val out = mutableListOf<Map<String, Any?>>()
            for (i in 0 until array.length()) {
                val item = array.optJSONObject(i) ?: continue
                out.add(
                    mapOf(
                        "uri" to item.optString("uri"),
                        "chatId" to item.optLong("chatId"),
                        "threadId" to item.optLong("threadId"),
                        "messageId" to item.optLong("messageId"),
                        "album" to item.optString("album")
                    )
                )
            }
            out
        } catch (_: Throwable) {
            emptyList()
        }
    }

    fun clearBackgroundBackupRecords(context: Context) {
        context.getSharedPreferences(TARGET_PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_BACKUP_RECORDS).apply()
        context.getSharedPreferences(TCloudGalleryWorker.PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(TCloudGalleryWorker.KEY_UPLOADED_URIS)
            .putLong(TCloudGalleryWorker.KEY_LAST_SCAN, 0L)
            .apply()
        try {
            TCloudBackgroundQueueStore.clear(context)
        } catch (_: Throwable) {}
    }

    fun forgetBackgroundBackupUris(context: Context, uris: Set<String>) {
        if (uris.isEmpty()) return

        val target = context.getSharedPreferences(TARGET_PREFS, Context.MODE_PRIVATE)
        val source = try {
            JSONArray(target.getString(KEY_BACKUP_RECORDS, "[]") ?: "[]")
        } catch (_: Throwable) {
            JSONArray()
        }
        val kept = JSONArray()
        for (index in 0 until source.length()) {
            val item = source.optJSONObject(index) ?: continue
            if (!uris.contains(item.optString("uri"))) kept.put(item)
        }
        target.edit().putString(KEY_BACKUP_RECORDS, kept.toString()).apply()

        val worker = context.getSharedPreferences(
            TCloudGalleryWorker.PREFS,
            Context.MODE_PRIVATE
        )
        val uploaded = worker.getStringSet(
            TCloudGalleryWorker.KEY_UPLOADED_URIS,
            emptySet()
        )?.toMutableSet() ?: mutableSetOf()
        uploaded.removeAll(uris)
        worker.edit().putStringSet(
            TCloudGalleryWorker.KEY_UPLOADED_URIS,
            uploaded
        ).apply()
    }

    private fun rememberBackgroundBackupRecord(
        context: Context,
        uri: String,
        chatId: Long,
        threadId: Long,
        messageId: Long,
        album: String
    ) {
        if (chatId == 0L || messageId == 0L) return
        val prefs = context.getSharedPreferences(TARGET_PREFS, Context.MODE_PRIVATE)
        val src = try {
            JSONArray(prefs.getString(KEY_BACKUP_RECORDS, "[]") ?: "[]")
        } catch (_: Throwable) {
            JSONArray()
        }
        val kept = JSONArray()
        for (i in 0 until src.length()) {
            val item = src.optJSONObject(i) ?: continue
            if (item.optString("uri") != uri) kept.put(item)
        }
        kept.put(
            JSONObject().apply {
                put("uri", uri)
                put("chatId", chatId)
                put("threadId", threadId)
                put("messageId", messageId)
                put("album", album)
            }
        )
        while (kept.length() > 10000) kept.remove(0)
        prefs.edit().putString(KEY_BACKUP_RECORDS, kept.toString()).apply()
    }

    @Synchronized
    fun ensureBackgroundInitialized(
        context: Context
    ): Boolean {
        if (client != null) {
            return true
        }

        val prefs =
            context.getSharedPreferences(
                PREFS,
                Context.MODE_PRIVATE
            )

        val storedId =
            prefs.getInt(
                KEY_API_ID,
                0
            )

        val storedHash =
            prefs.getString(
                KEY_API_HASH,
                ""
            ).orEmpty()

        if (
            storedId <= 0 ||
            storedHash.isBlank()
        ) {
            return false
        }

        apiId = storedId
        apiHash = storedHash
        state = "initializing"

        Client.setLogMessageHandler(
            2
        ) { verbosity, message ->
            if (verbosity <= 2) {
                android.util.Log.d(
                    "TCloud-TDLib-BG",
                    message
                )
            }
        }

        client =
            Client.create(
                { update ->
                    handleBackgroundUpdate(
                        context.applicationContext,
                        update
                    )
                },
                { error ->
                    android.util.Log.e(
                        "TCloud-TDLib-BG",
                        "Update handler: " +
                            (error.message
                                ?: error.toString())
                    )
                },
                { error ->
                    android.util.Log.e(
                        "TCloud-TDLib-BG",
                        "Request handler: " +
                            (error.message
                                ?: error.toString())
                    )
                }
            )

        return true
    }

    private fun handleBackgroundUpdate(
        context: Context,
        update: TdApi.Object
    ) {
        handleMessageSendUpdate(update)

        if (
            update !is
                TdApi.UpdateAuthorizationState
        ) {
            return
        }

        when (
            update.authorizationState.constructor
        ) {
            TdApi
                .AuthorizationStateWaitTdlibParameters
                .CONSTRUCTOR -> {
                state = "initializing"

                val databaseDir =
                    File(
                        context.filesDir,
                        "tdlib/database"
                    )

                val filesDir =
                    File(
                        context.filesDir,
                        "tdlib/files"
                    )

                databaseDir.mkdirs()
                filesDir.mkdirs()

                val parameters =
                    TdApi.SetTdlibParameters()

                parameters.databaseDirectory =
                    databaseDir.absolutePath

                parameters.filesDirectory =
                    filesDir.absolutePath

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
                    "0.9"

                send(
                    parameters
                )
            }

            TdApi
                .AuthorizationStateWaitPhoneNumber
                .CONSTRUCTOR ->
                state = "phone"

            TdApi
                .AuthorizationStateWaitCode
                .CONSTRUCTOR ->
                state = "code"

            TdApi
                .AuthorizationStateWaitPassword
                .CONSTRUCTOR ->
                state = "password"

            TdApi
                .AuthorizationStateWaitEmailAddress
                .CONSTRUCTOR ->
                state = "email_address"

            TdApi
                .AuthorizationStateWaitEmailCode
                .CONSTRUCTOR ->
                state = "email_code"

            TdApi
                .AuthorizationStateWaitRegistration
                .CONSTRUCTOR ->
                state = "registration"

            TdApi
                .AuthorizationStateWaitOtherDeviceConfirmation
                .CONSTRUCTOR ->
                state = "other_device"

            TdApi
                .AuthorizationStateReady
                .CONSTRUCTOR ->
                state = "ready"

            TdApi
                .AuthorizationStateLoggingOut
                .CONSTRUCTOR ->
                state = "logging_out"

            TdApi
                .AuthorizationStateClosing
                .CONSTRUCTOR ->
                state = "closing"

            TdApi
                .AuthorizationStateClosed
                .CONSTRUCTOR -> {
                state = "closed"
                client = null
            }

            else ->
                state = "authorization"
        }
    }

    private fun send(
        function: TdApi.Function<*>
    ) {
        client?.send(function) {
                response ->
            if (
                response is TdApi.Error
            ) {
                android.util.Log.e(
                    "TCloud-TDLib-BG",
                    "${response.code}: ${response.message}"
                )
            }
        }
    }

    fun processBackgroundQueue(
        context: Context
    ): Boolean {
        synchronized(this) {
            if (queueProcessing) {
                return false
            }

            queueProcessing = true
        }

        return try {
            processBackgroundQueueInternal(
                context
            )
        } finally {
            synchronized(this) {
                queueProcessing = false
            }
        }
    }
    private fun processBackgroundQueueInternal(
        context: Context
    ): Boolean {        cleanupOldUploadTemps(context)

        val backgroundPrefs =
            context.getSharedPreferences(
                TCloudGalleryWorker.PREFS,
                Context.MODE_PRIVATE
            )
        val blockedUntil =
            backgroundPrefs.getLong(
                TCloudGalleryWorker.KEY_RATE_LIMIT_UNTIL,
                0L
            )
        if (blockedUntil > System.currentTimeMillis()) {
            return false
        }

        if (
            !ensureBackgroundInitialized(
                context
            )
        ) {
            return false
        }

        val deadline =
            System.currentTimeMillis() +
                25000L

        while (
            state != "ready" &&
            System.currentTimeMillis() <
                deadline
        ) {
            if (
                state == "phone" ||
                state == "code" ||
                state == "password" ||
                state == "email_address" ||
                state == "email_code" ||
                state == "registration"
            ) {
                return false
            }

            Thread.sleep(250L)
        }

        if (state != "ready") {
            return false
        }

        val targetPrefs =
            context.getSharedPreferences(
                TARGET_PREFS,
                Context.MODE_PRIVATE
            )

        val chatId =
            targetPrefs.getLong(
                KEY_TARGET_CHAT_ID,
                0L
            )

        val threadId =
            targetPrefs.getLong(
                KEY_TARGET_THREAD_ID,
                0L
            )
        val albumTargets = loadBackgroundAlbumTargets(context)


        if (chatId == 0L) {
            return false
        }

        val queueFile =
            File(
                context.filesDir,
                TCloudGalleryWorker
                    .QUEUE_FILE
            )

        if (!queueFile.exists()) {
            return true
        }

        val source = TCloudBackgroundQueueStore.read(context)

        if (source.length() == 0) {
            return true
        }

        val kept =
            JSONArray()

        var rateLimited = false

        for (
            index in 0 until
                source.length()
        ) {
            val item =
                source.optJSONObject(
                    index
                ) ?: continue

            val uri =
                item.optString(
                    "uri"
                )

            if (uri.isBlank()) {
                continue
            }

            if (rateLimited) {
                kept.put(item)
                continue
            }

            val album = item.optString("album").trim()
            val targetThreadId =
                if (album.isBlank()) threadId
                else albumTargets[album.lowercase()] ?: 0L

            if (album.isNotBlank() && targetThreadId == 0L) {
                kept.put(item)
                continue
            }

            val local =
                try {
                    copyUriForUpload(
                        context,
                        Uri.parse(uri),
                        item.optString(
                            "name"
                        )
                    )
                } catch (
                    _: Throwable
                ) {
                    null
                }

            if (local == null) {
                // TCLOUD_NATIVE_RETRY_COPY_NO_LOSS_1053
                item.put(
                    "attempts",
                    item.optInt("attempts", 0) + 1
                )
                kept.put(item)
                continue
            }

            val messageId =
                try {
                    sendDocumentBlocking(
                        chatId,
                        if (album.isBlank()) targetThreadId else 0L,
                        if (album.isBlank()) 0L else targetThreadId,
                        local.absolutePath
                    )
                } catch (_: Throwable) {
                    0L
                }

            if (messageId == 0L) {
                val attempts =
                    item.optInt(
                        "attempts",
                        0
                    ) + 1

                item.put(
                    "attempts",
                    attempts
                )

                kept.put(item)

                val retrySeconds =
                    Regex(
                        "(?:retry after|retry_after|flood_wait[_ ]?)(\\d+)",
                        RegexOption.IGNORE_CASE
                    ).find(lastSendError)
                        ?.groupValues
                        ?.getOrNull(1)
                        ?.toLongOrNull()

                if (retrySeconds != null && retrySeconds > 0L) {
                    val until =
                        System.currentTimeMillis() +
                            (retrySeconds + 5L) * 1000L
                    backgroundPrefs.edit()
                        .putLong(
                            TCloudGalleryWorker.KEY_RATE_LIMIT_UNTIL,
                            until
                        )
                        .apply()
                    rateLimited = true
                }

                try {
                    local.delete()
                    local.parentFile?.delete()
                } catch (_: Throwable) {}
            } else {
                rememberUploadedUri(
                    context,
                    uri
                )
                rememberBackgroundBackupRecord(
                    context,
                    uri,
                    chatId,
                    targetThreadId,
                    messageId,
                    album
                )

                try {
                    local.delete()
                    local.parentFile?.delete()
                } catch (_: Throwable) {}
            }
        }

        return TCloudBackgroundQueueStore
            .reconcileProcessed(context, source, kept) == 0
    }

    private fun rememberUploadedUri(
        context: Context,
        uri: String
    ) {
        if (uri.isBlank()) {
            return
        }

        val prefs =
            context.getSharedPreferences(
                TCloudGalleryWorker.PREFS,
                Context.MODE_PRIVATE
            )

        val current =
            prefs.getStringSet(
                TCloudGalleryWorker
                    .KEY_UPLOADED_URIS,
                emptySet()
            )?.toMutableList()
                ?: mutableListOf()

        current.remove(uri)
        current.add(uri)

        val bounded =
            if (current.size <= 8000) {
                current
            } else {
                current.takeLast(8000)
            }

        prefs.edit()
            .putStringSet(
                TCloudGalleryWorker
                    .KEY_UPLOADED_URIS,
                bounded.toSet()
            )
            .apply()
    }
    private fun sendDocumentBlocking(
        chatId: Long,
        legacyThreadId: Long,
        forumTopicId: Long,
        path: String
    ): Long {
        val current =
            client ?: return 0L

        val source =
            File(path)

        if (
            chatId == 0L ||
            path.isBlank() ||
            !source.exists() ||
            !source.isFile
        ) {
            return 0L
        }

        lastSendError = ""

        return try {
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
                    forumTopicId != 0L ->
                        TdApi.MessageTopicForum().apply {
                            this.forumTopicId =
                                forumTopicId.toInt()
                        }

                    legacyThreadId != 0L ->
                        TdApi.MessageTopicThread().apply {
                            messageThreadId =
                                legacyThreadId
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

            val latch =
                CountDownLatch(1)

            var sentMessage: TdApi.Message? = null

            current.send(request) {
                    response ->

                when (response) {
                    is TdApi.Message -> sentMessage = response
                    is TdApi.Error -> lastSendError = response.message
                }

                latch.countDown()
            }

            if (
                !latch.await(
                    90,
                    TimeUnit.SECONDS
                )
            ) {
                0L
            } else {
                val accepted = sentMessage
                if (accepted == null) 0L else awaitFinalMessageId(accepted)
            }
        } catch (
            error: Throwable
        ) {
            lastSendError = error.message ?: error.toString()
            0L
        }
    }

private fun createTdObject(
        typeName: String,
        values: Map<String, Any?>
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
                    "TDLib $typeName sem construtor vazio."
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
                ) ?: continue

            field.isAccessible = true

            field.set(
                instance,
                convertValue(
                    field.type,
                    value
                )
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
            target ==
                Int::class.javaPrimitiveType ||
            target ==
                Int::class.java
        ) {
            return (
                value as Number
            ).toInt()
        }

        if (
            target ==
                Long::class.javaPrimitiveType ||
            target ==
                Long::class.java
        ) {
            return (
                value as Number
            ).toLong()
        }

        if (
            target ==
                Boolean::class.javaPrimitiveType ||
            target ==
                Boolean::class.java
        ) {
            return value as Boolean
        }

        if (
            target ==
                String::class.java
        ) {
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
                val nested =
                    value.entries
                        .filter {
                            it.key
                                ?.toString() !=
                                "_type"
                        }
                        .associate {
                            it.key.toString() to
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

    private fun cleanupOldUploadTemps(
        context: Context
    ) {
        try {
            val directory =
                File(
                    context.cacheDir,
                    "tcloud_background_uploads"
                )

            if (!directory.exists()) {
                return
            }

            val cutoff =
                System.currentTimeMillis() -
                    24L * 60L * 60L * 1000L

            directory.listFiles()
                ?.filter { it.lastModified() < cutoff }
                ?.forEach {
                    try {
                        if (it.isDirectory) it.deleteRecursively() else it.delete()
                    } catch (_: Throwable) {}
                }
        } catch (_: Throwable) {}
    }
    private fun copyUriForUpload(
        context: Context,
        uri: Uri,
        suggestedName: String
    ): File {
        var name =
            suggestedName.trim()

        if (name.isBlank()) {
            context.contentResolver
                .query(
                    uri,
                    null,
                    null,
                    null,
                    null
                )?.use {
                        cursor ->
                    val index =
                        cursor.getColumnIndex(
                            OpenableColumns
                                .DISPLAY_NAME
                        )

                    if (
                        index >= 0 &&
                        cursor.moveToFirst()
                    ) {
                        name =
                            cursor.getString(
                                index
                            ).orEmpty()
                    }
                }
        }

        if (name.isBlank()) {
            name =
                "midia_${System.currentTimeMillis()}"
        }

        val safeName =
            name.replace(
                Regex(
                    "[\\\\/:*?\"<>|]"
                ),
                "_"
            )

        val dir =
            File(
                context.cacheDir,
                "tcloud_background_uploads"
            )

        dir.mkdirs()

        // Um diretorio exclusivo evita colisoes sem alterar o nome que o
        // Telegram exibe ao usuario.
        val itemDir = File(
            dir,
            "${System.currentTimeMillis()}_${System.nanoTime()}"
        )
        itemDir.mkdirs()
        val destination = File(itemDir, safeName)

        context.contentResolver
            .openInputStream(uri)
            ?.use {
                    input ->
                destination
                    .outputStream()
                    .use {
                            output ->
                        input.copyTo(output)
                    }
            }
            ?: throw IllegalStateException(
                "Nao foi possivel abrir a midia."
            )

        return destination
    }

}
