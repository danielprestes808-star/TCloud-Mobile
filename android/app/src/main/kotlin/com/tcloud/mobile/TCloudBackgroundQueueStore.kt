package com.tcloud.mobile

import android.content.Context
import android.util.AtomicFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Single crash-safe owner for the background gallery queue. */
object TCloudBackgroundQueueStore {
    private val lock = Any()

    private fun file(context: Context) =
        File(context.filesDir, TCloudGalleryWorker.QUEUE_FILE)

    private fun readLocked(target: File): JSONArray {
        if (!target.exists()) return JSONArray()
        return try {
            val bytes = AtomicFile(target).readFully()
            JSONArray(bytes.toString(Charsets.UTF_8))
        } catch (_: Throwable) {
            JSONArray()
        }
    }

    private fun writeLocked(target: File, values: JSONArray) {
        val atomic = AtomicFile(target)
        val stream = atomic.startWrite()
        try {
            stream.write(values.toString().toByteArray(Charsets.UTF_8))
            stream.flush()
            atomic.finishWrite(stream)
        } catch (error: Throwable) {
            atomic.failWrite(stream)
            throw error
        }
    }

    fun read(context: Context): JSONArray = synchronized(lock) {
        JSONArray(readLocked(file(context)).toString())
    }

    fun count(context: Context): Int = synchronized(lock) {
        readLocked(file(context)).length()
    }

    fun mergeScanned(context: Context, scanned: JSONArray, maximum: Int) = synchronized(lock) {
        val target = file(context)
        val current = readLocked(target)
        val known = mutableSetOf<String>()
        val merged = JSONArray()
        for (index in 0 until current.length()) {
            val item = current.optJSONObject(index) ?: continue
            val uri = item.optString("uri")
            if (uri.isBlank() || !known.add(uri)) continue
            merged.put(item)
        }
        for (index in 0 until scanned.length()) {
            val item = scanned.optJSONObject(index) ?: continue
            val uri = item.optString("uri")
            if (uri.isBlank() || !known.add(uri)) continue
            merged.put(item)
        }
        while (merged.length() > maximum) merged.remove(0)
        writeLocked(target, merged)
    }

    fun reconcileProcessed(context: Context, original: JSONArray, kept: JSONArray): Int =
        synchronized(lock) {
            val originalUris = mutableSetOf<String>()
            for (index in 0 until original.length()) {
                original.optJSONObject(index)?.optString("uri")
                    ?.takeIf { it.isNotBlank() }
                    ?.let(originalUris::add)
            }
            val keptByUri = mutableMapOf<String, JSONObject>()
            for (index in 0 until kept.length()) {
                val item = kept.optJSONObject(index) ?: continue
                item.optString("uri").takeIf { it.isNotBlank() }?.let { keptByUri[it] = item }
            }
            val current = readLocked(file(context))
            val result = JSONArray()
            val written = mutableSetOf<String>()
            for (index in 0 until current.length()) {
                val currentItem = current.optJSONObject(index) ?: continue
                val uri = currentItem.optString("uri")
                if (uri.isBlank() || !written.add(uri)) continue
                if (uri in originalUris) {
                    keptByUri[uri]?.let(result::put)
                } else {
                    result.put(currentItem)
                }
            }
            writeLocked(file(context), result)
            result.length()
        }

    fun removeUris(context: Context, uris: Set<String>) = synchronized(lock) {
        if (uris.isEmpty()) return@synchronized
        val current = readLocked(file(context))
        val kept = JSONArray()
        for (index in 0 until current.length()) {
            val item = current.optJSONObject(index) ?: continue
            if (item.optString("uri") !in uris) kept.put(item)
        }
        writeLocked(file(context), kept)
    }

    fun clear(context: Context) = synchronized(lock) {
        AtomicFile(file(context)).delete()
    }
}
