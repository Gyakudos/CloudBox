package dev.cloudbox.cloudbox

import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.ArrayDeque
import java.util.UUID

/**
 * Picks a whole folder on Android and stages its files for the Dart transfer engine.
 *
 * `dart:io` cannot read the `content://` URIs the Storage Access Framework returns (and scoped
 * storage blocks raw paths on modern Android), so the plugin copies each file into a private cache
 * directory and hands Dart ordinary file paths. The relative paths keep the picked folder's name
 * as the first segment, matching the layout the agent writes under the sync folder.
 */
class FolderPickerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
    PluginRegistry.ActivityResultListener {

    private data class Entry(val relativePath: String, val uri: String)

    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var channel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        activity = binding.activity
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity()
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFolder" -> pickFolder(result)
            "clearCache" -> {
                clearCache()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("already_active", "A folder picker is already open", null)
            return
        }
        val currentActivity = activity
        if (currentActivity == null) {
            result.error("no_activity", "The folder picker needs a foreground activity", null)
            return
        }
        pending = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
        }
        try {
            currentActivity.startActivityForResult(intent, REQUEST_PICK_FOLDER)
        } catch (e: Exception) {
            pending = null
            result.error("explorer_not_found", "No app on this device can pick a folder", e.message)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK_FOLDER) return false
        val result = pending ?: return true
        pending = null

        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null) // the user backed out
            return true
        }
        val treeUri = data.data!!
        val appContext = context
        if (appContext == null) {
            result.error("no_context", "The app lost its context while picking a folder", null)
            return true
        }

        // Enumerating and copying a large tree must not block the main thread. The result is
        // marshalled back onto it, as MethodChannel requires.
        Thread {
            try {
                try {
                    appContext.contentResolver.takePersistableUriPermission(
                        treeUri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (e: SecurityException) {
                    // Not every provider offers a durable grant. We only need it for this pick,
                    // because the files are staged into our own cache below.
                    Log.w(TAG, "could not persist folder permission", e)
                }
                val files = collect(treeUri, appContext)
                Handler(Looper.getMainLooper()).post { result.success(files) }
            } catch (e: Exception) {
                Log.e(TAG, "could not read the selected folder", e)
                Handler(Looper.getMainLooper()).post {
                    result.error("folder_error", e.message ?: "Could not read that folder", null)
                }
            }
        }.start()
        return true
    }

    /** Walks the SAF tree and stages every document as a real file under the app cache. */
    private fun collect(treeUri: Uri, appContext: Context): List<Map<String, Any>> {
        val resolver = appContext.contentResolver
        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val rootDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, rootId)
        val rootName = displayName(resolver, rootDocUri)
            ?: rootId.substringAfter(':', rootId).ifBlank { "Folder" }
        val prefix = safeSegment(rootName) + "/"

        val entries = mutableListOf<Entry>()
        val stack = ArrayDeque<Pair<String, String>>()
        stack.add(rootId to prefix)

        // Iterative walk: photo libraries can nest surprisingly deeply, and a recursive Kotlin
        // function would risk a stack overflow on a large tree.
        var visited = 0
        while (stack.isNotEmpty() && visited < MAX_DOCUMENTS) {
            visited++
            val (parentId, pathPrefix) = stack.removeLast()
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, parentId)
            val projection = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            resolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
                while (cursor.moveToNext()) {
                    val id = cursor.getString(0) ?: continue
                    val name = cursor.getString(1) ?: continue
                    val mime = cursor.getString(2)
                    val childUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, id)
                    if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                        stack.add(id to (pathPrefix + safeSegment(name) + "/"))
                    } else {
                        entries.add(Entry(pathPrefix + safeSegment(name), childUri.toString()))
                    }
                }
            }
        }

        val session = File(File(appContext.cacheDir, CACHE_DIR), UUID.randomUUID().toString())
        val rootPath = session.canonicalPath
        val staged = mutableListOf<Map<String, Any>>()
        for (entry in entries) {
            val destination = File(session, entry.relativePath)
            val canonical = destination.canonicalPath
            // A document's display name is provider-controlled; never let it escape our cache.
            if (canonical != rootPath && !canonical.startsWith(rootPath + File.separator)) continue
            destination.parentFile?.mkdirs()
            val input = resolver.openInputStream(Uri.parse(entry.uri)) ?: continue
            input.use { source ->
                FileOutputStream(destination).use { target ->
                    source.copyTo(target, COPY_BUFFER)
                }
            }
            staged += mapOf(
                "relativePath" to entry.relativePath,
                "path" to destination.path,
                "size" to destination.length(),
            )
        }
        return staged
    }

    private fun displayName(resolver: ContentResolver, uri: Uri): String? {
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getString(0)
        }
        return null
    }

    /** Keeps a provider-supplied name usable as one path segment without dropping the file. */
    private fun safeSegment(name: String): String {
        val cleaned = name.map { ch ->
            if (ch == '/' || ch == '\\' || ch < ' ' || ch == '\u007F') '_' else ch
        }.joinToString("").trim()
        // Only the traversal segments need rewriting: dotfiles such as .gitignore are uploaded
        // with their real names.
        return when (cleaned) {
            "", ".", ".." -> "unnamed"
            else -> cleaned
        }
    }

    private fun clearCache() {
        val appContext = context ?: return
        deleteTree(File(appContext.cacheDir, CACHE_DIR))
    }

    private fun deleteTree(file: File) {
        if (!file.exists()) return
        if (file.isDirectory) file.listFiles()?.forEach { deleteTree(it) }
        file.delete()
    }

    private companion object {
        const val TAG = "CloudBoxFolderPicker"
        const val CHANNEL = "dev.cloudbox.cloudbox/folder"
        const val REQUEST_PICK_FOLDER = 0x5C01
        const val CACHE_DIR = "cloudbox-folders"
        const val COPY_BUFFER = 256 * 1024
        const val MAX_DOCUMENTS = 100_000
    }
}
