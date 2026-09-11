package com.tcloud.mobile

import android.database.Cursor
import android.database.MatrixCursor
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
                    Root.COLUMN_FLAGS -> row.add(Root.FLAG_SUPPORTS_SEARCH or Root.FLAG_LOCAL_ONLY)
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
        else resolve(documentId)?.let { addDocument(cursor, it, documentId, it.name) }
        return cursor
    }

    override fun queryChildDocuments(parentDocumentId: String, projection: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(documentColumns(projection))
        if (parentDocumentId == rootId) {
            roots().forEachIndexed { index, root ->
                addDocument(cursor, root, id(root), if (index == 0) "Arquivos offline" else "Cache ${index + 1}")
            }
        } else {
            resolve(parentDocumentId)?.takeIf { it.isDirectory }?.listFiles()
                ?.sortedWith(compareByDescending<File> { it.isDirectory }.thenBy { it.name.lowercase() })
                ?.take(1000)?.forEach { addDocument(cursor, it, id(it), it.name) }
        }
        return cursor
    }

    override fun querySearchDocuments(rootId: String, query: String, projection: Array<out String>?): Cursor {
        val cursor = MatrixCursor(documentColumns(projection))
        val needle = query.trim().lowercase()
        roots().forEach { root ->
            root.walkTopDown().maxDepth(8).filter { it.isFile && it.name.lowercase().contains(needle) }
                .take(200).forEach { addDocument(cursor, it, id(it), it.name) }
        }
        return cursor
    }

    override fun openDocument(documentId: String, mode: String, signal: CancellationSignal?): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("TCloud provider is read-only")
        val file = resolve(documentId)?.takeIf { it.isFile }
            ?: throw java.io.FileNotFoundException(documentId)
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun documentColumns(projection: Array<out String>?) = projection ?: arrayOf(
        Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE,
        Document.COLUMN_SIZE, Document.COLUMN_LAST_MODIFIED, Document.COLUMN_FLAGS
    )

    private fun addDocument(cursor: MatrixCursor, file: File?, documentId: String, name: String) {
        val directory = file == null || file.isDirectory
        val extension = file?.extension?.lowercase().orEmpty()
        val mime = if (directory) Document.MIME_TYPE_DIR
        else MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "application/octet-stream"
        val row = cursor.newRow()
        cursor.columnNames.forEach { column ->
            when (column) {
                Document.COLUMN_DOCUMENT_ID -> row.add(documentId)
                Document.COLUMN_DISPLAY_NAME -> row.add(name)
                Document.COLUMN_MIME_TYPE -> row.add(mime)
                Document.COLUMN_SIZE -> row.add(if (directory) null else file?.length())
                Document.COLUMN_LAST_MODIFIED -> row.add(file?.lastModified() ?: 0L)
                Document.COLUMN_FLAGS -> row.add(if (directory) 0 else Document.FLAG_SUPPORTS_THUMBNAIL)
                else -> row.add(null)
            }
        }
    }
}
