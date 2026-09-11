package com.tcloud.mobile

import android.database.Cursor
import android.database.MatrixCursor
import android.content.res.AssetFileDescriptor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.util.Base64
import android.webkit.MimeTypeMap
import java.io.File

/** Makes locally available TCloud files visible in Android's system file picker. */
class TCloudDocumentsProvider : DocumentsProvider() {
    private val rootId = "tcloud"
    private val categories = linkedMapOf(
        "images" to "Imagens",
        "videos" to "Vídeos",
        "audio" to "Áudios",
        "documents" to "Documentos",
        "other" to "Outros arquivos",
    )

    private fun categoryId(key: String) = "category:$key"

    private fun localFiles(): Sequence<File> = roots().asSequence()
        .flatMap { it.walkTopDown().maxDepth(8) }
        .filter { it.isFile && visible(it) }
        .distinctBy { it.canonicalPath }

    private fun roots(): List<File> {
        val context = context ?: return emptyList()
        val candidates = mutableListOf<File>()
        candidates += File(context.filesDir, "tdlib/files")
        File(context.filesDir, "tdlib").listFiles()?.filter { it.isDirectory }?.forEach {
            candidates += File(it, "files")
        }
        context.externalCacheDir?.let { candidates += it }
        candidates += context.cacheDir
        return candidates.filter { it.isDirectory }.map { it.canonicalFile }.distinct()
    }

    private fun id(file: File): String = Base64.encodeToString(
        file.canonicalPath.toByteArray(Charsets.UTF_8),
        Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING
    )

    private fun resolve(documentId: String): File? {
        if (documentId == rootId) return null
        return try {
            val path = String(
                Base64.decode(documentId, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING),
                Charsets.UTF_8,
            )
            val file = File(path).canonicalFile
            file.takeIf { target -> roots().any { root -> target.path == root.path || target.path.startsWith(root.path + File.separator) } }
        } catch (_: Throwable) {
            null
        }
    }

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val columns = projection ?: arrayOf(
            Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID, Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY, Root.COLUMN_FLAGS, Root.COLUMN_MIME_TYPES,
            Root.COLUMN_AVAILABLE_BYTES
        )
        return MatrixCursor(columns).apply {
            val row = newRow()
            columns.forEach { column ->
                when (column) {
                    Root.COLUMN_ROOT_ID -> row.add(rootId)
                    Root.COLUMN_DOCUMENT_ID -> row.add(rootId)
                    Root.COLUMN_TITLE -> row.add("TCloud")
                    Root.COLUMN_SUMMARY -> row.add("Arquivos disponíveis neste aparelho")
                    Root.COLUMN_FLAGS -> row.add(
                        Root.FLAG_SUPPORTS_SEARCH or Root.FLAG_SUPPORTS_RECENTS or Root.FLAG_LOCAL_ONLY
                    )
                    Root.COLUMN_MIME_TYPES -> row.add("*/*")
                    Root.COLUMN_AVAILABLE_BYTES -> row.add(context?.filesDir?.usableSpace ?: 0L)
                    else -> row.add(null)
                }
            }
        }
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(documentColumns(projection))
        if (documentId == rootId) addDocument(cursor, null, rootId, "TCloud")
        else if (documentId.startsWith("category:")) {
            val key = documentId.removePrefix("category:")
            categories[key]?.let { addDocument(cursor, null, documentId, it) }
        }
        else resolve(documentId)?.let { addDocument(cursor, it, documentId, it.name) }
        return cursor
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(documentColumns(projection))
        if (parentDocumentId == rootId) {
            categories.forEach { (key, label) ->
                addDocument(cursor, null, categoryId(key), label)
            }
        } else if (parentDocumentId.startsWith("category:")) {
            val key = parentDocumentId.removePrefix("category:")
            localFiles().filter { categoryFor(it) == key }
                .sortedByDescending { it.lastModified() }
                .take(1000)
                .forEach { addDocument(cursor, it, id(it), it.name) }
        } else {
            resolve(parentDocumentId)?.takeIf { it.isDirectory }?.listFiles()
                ?.sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() })
                ?.filter(::visible)
                ?.take(1000)?.forEach { addDocument(cursor, it, id(it), it.name) }
        }
        return cursor
    }

    override fun querySearchDocuments(rootId: String, query: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(documentColumns(projection))
        val needle = query.trim().lowercase()
        roots().forEach { root ->
            root.walkTopDown().maxDepth(8).filter {
                it.isFile && visible(it) && it.name.lowercase().contains(needle)
            }
                .take(200).forEach { addDocument(cursor, it, id(it), it.name) }
        }
        return cursor
    }

    override fun queryRecentDocuments(rootId: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(documentColumns(projection))
        localFiles()
            .sortedByDescending { it.lastModified() }
            .take(64)
            .forEach { addDocument(cursor, it, id(it), it.name) }
        return cursor
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("TCloud provider is read-only")
        val file = resolve(documentId)?.takeIf { it.isFile }
            ?: throw java.io.FileNotFoundException(documentId)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point,
        signal: CancellationSignal?
    ): AssetFileDescriptor {
        val file = resolve(documentId)?.takeIf { it.isFile && mime(it).startsWith("image/") }
            ?: throw java.io.FileNotFoundException(documentId)
        return AssetFileDescriptor(
            ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY),
            0,
            AssetFileDescriptor.UNKNOWN_LENGTH,
        )
    }

    private fun documentColumns(projection: Array<out String>?) = projection ?: arrayOf(
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
        Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS
    )

    private fun visible(file: File): Boolean {
        val name = file.name.lowercase()
        return !file.isHidden && !name.endsWith(".part") && !name.endsWith(".tmp") &&
            !name.endsWith(".db") && !name.endsWith(".db-shm") &&
            !name.endsWith(".db-wal") && name != "tcloud-mobile-update.apk"
    }

    private fun mime(file: File): String {
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(file.extension.lowercase())
            ?: "application/octet-stream"
    }

    private fun categoryFor(file: File): String {
        val type = mime(file)
        return when {
            type.startsWith("image/") -> "images"
            type.startsWith("video/") -> "videos"
            type.startsWith("audio/") -> "audio"
            type.startsWith("text/") || type == "application/pdf" ||
                type.contains("document") || type.contains("sheet") ||
                type.contains("presentation") || type.contains("zip") -> "documents"
            else -> "other"
        }
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        if (parentDocumentId == rootId) {
            return documentId.startsWith("category:") || resolve(documentId) != null
        }
        if (parentDocumentId.startsWith("category:")) {
            val file = resolve(documentId) ?: return false
            return categoryFor(file) == parentDocumentId.removePrefix("category:")
        }
        val parent = resolve(parentDocumentId) ?: return false
        val child = resolve(documentId) ?: return false
        return child.path.startsWith(parent.path + File.separator)
    }

    private fun addDocument(cursor: MatrixCursor, file: File?, documentId: String, name: String) {
        val directory = file == null || file.isDirectory
        val mime = if (directory) Document.MIME_TYPE_DIR
        else mime(file!!)
        val row = cursor.newRow()
        cursor.columnNames.forEach { column ->
            when (column) {
                Document.COLUMN_DOCUMENT_ID -> row.add(documentId)
                Document.COLUMN_DISPLAY_NAME -> row.add(name)
                Document.COLUMN_MIME_TYPE -> row.add(mime)
                Document.COLUMN_SIZE -> row.add(if (directory) null else file?.length())
                Document.COLUMN_LAST_MODIFIED -> row.add(file?.lastModified() ?: 0L)
                Document.COLUMN_FLAGS -> row.add(
                    if (!directory && mime.startsWith("image/")) Document.FLAG_SUPPORTS_THUMBNAIL else 0
                )
                else -> row.add(null)
            }
        }
    }
}
