package com.example.sticker_manager

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
    private val channelName = "sticker_manager/platform"
    private val shareEventChannelName = "sticker_manager/share_events"
    private val pendingFiles = mutableListOf<String>()
    private val pendingIntentFiles = mutableMapOf<String, MutableList<String>>()
    private val pendingShareErrors = mutableListOf<String>()
    private var pendingFilesLoaded = false
    private var shareEventSink: EventChannel.EventSink? = null
    private var lastCapturedIntentIdentity: Int? = null

    private val pendingFilePreferences by lazy {
        getSharedPreferences(SHARE_PREFERENCES, MODE_PRIVATE)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        loadPendingFiles()
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, shareEventChannelName)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    shareEventSink = events
                    loadPendingFiles()
                    if (pendingFiles.isNotEmpty()) {
                        events?.success(pendingFiles.toList())
                    }
                }

                override fun onCancel(arguments: Any?) {
                    shareEventSink = null
                }
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "initialize" -> { captureIntent(intent); result.success(null) }
                "consumeSharedFiles" -> {
                    loadPendingFiles()
                    result.success(pendingFiles.toList())
                }
                "ackSharedFiles" -> {
                    val files = call.argument<List<String>>("files") ?: emptyList()
                    acknowledgeSharedFiles(files)
                    result.success(null)
                }
                "consumeShareErrors" -> {
                    loadPendingFiles()
                    val errors = pendingShareErrors.toList()
                    pendingShareErrors.clear()
                    persistPendingFiles()
                    result.success(errors)
                }
                "pasteSticker" -> {
                    val filePath = call.argument<String>("path")
                    result.success(filePath != null && copyToClipboard(filePath))
                }
                "isOverlayGranted" -> result.success(Settings.canDrawOverlays(this))
                "isFloatingPanelRunning" -> result.success(FloatingPanelService.running)
                "peekFloatingUsage" -> {
                    result.success(FloatingPanelService.peekUsageEvents(this))
                }
                "ackFloatingUsage" -> {
                    val ids = call.argument<List<String>>("ids") ?: emptyList()
                    FloatingPanelService.ackUsageEvents(this, ids)
                    result.success(null)
                }
                "startFloatingPanel" -> {
                    if (!Settings.canDrawOverlays(this)) {
                        result.success(false)
                    } else {
                        val stickers = call.argument<List<Map<String, Any?>>>("stickers") ?: emptyList()
                        FloatingPanelService.updateStickers(this, stickers)
                        try {
                            if (FloatingPanelService.requestStart()) {
                                val serviceIntent = Intent(this, FloatingPanelService::class.java)
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                    ContextCompat.startForegroundService(this, serviceIntent)
                                } else {
                                    startService(serviceIntent)
                                }
                            }
                            result.success(true)
                        } catch (error: Throwable) {
                            FloatingPanelService.cancelStartRequest()
                            result.error(
                                "floating_panel_start_failed",
                                error.message ?: "无法启动悬浮面板",
                                null,
                            )
                        }
                    }
                }
                "stopFloatingPanel" -> {
                    FloatingPanelService.requestStop()
                    stopService(Intent(this, FloatingPanelService::class.java))
                    result.success(true)
                }
                "syncFloatingPanel" -> {
                    val stickers = call.argument<List<Map<String, Any?>>>("stickers") ?: emptyList()
                    FloatingPanelService.updateStickers(this, stickers)
                    result.success(null)
                }
                "openOverlaySettings" -> {
                    val settingsIntent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:$packageName"),
                    )
                    startActivity(settingsIntent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureIntent(intent)
    }

    private fun captureIntent(source: Intent?) {
        if (source == null) return
        if (source.action != Intent.ACTION_SEND && source.action != Intent.ACTION_SEND_MULTIPLE) return
        val identity = System.identityHashCode(source)
        if (lastCapturedIntentIdentity == identity) return
        lastCapturedIntentIdentity = identity
        loadPendingFiles()
        val uris = mutableListOf<Uri>()
        source.extras?.get(Intent.EXTRA_STREAM)?.let { stream ->
            when (stream) {
                is Uri -> uris.add(stream)
                is List<*> -> uris.addAll(stream.filterIsInstance<Uri>())
            }
        }
        source.clipData?.let { clipData ->
            for (index in 0 until clipData.itemCount) {
                clipData.getItemAt(index).uri?.let { uris.add(it) }
            }
        }
        source.data?.let { uris.add(it) }
        val fingerprint = intentFingerprint(source, uris)
        val previousFiles = pendingIntentFiles[fingerprint]
            ?.filter { pendingFiles.contains(it) && File(it).exists() }
            ?: emptyList()
        if (previousFiles.isNotEmpty()) return
        pendingIntentFiles.remove(fingerprint)
        val captured = mutableListOf<String>()
        var copiedBytes = 0L
        uris.distinct().forEach { uri ->
            if (copiedBytes >= MAX_SHARED_TOTAL_BYTES) {
                recordShareError("分享文件总大小超过 ${formatBytes(MAX_SHARED_TOTAL_BYTES)}，已停止接收")
                return@forEach
            }
            val extension = safeShareExtension(uri)
            val file = File(cacheDir, "shared_${System.nanoTime()}.$extension")
            val copy = copyUriBounded(uri, file, MAX_SHARED_TOTAL_BYTES - copiedBytes)
            if (copy.error != null) {
                file.delete()
                recordShareError(copy.error)
                return@forEach
            }
            copiedBytes += copy.bytes
            if (copy.bytes > 0L && !pendingFiles.contains(file.absolutePath)) {
                pendingFiles.add(file.absolutePath)
                captured.add(file.absolutePath)
            } else {
                file.delete()
            }
        }
        if (captured.isNotEmpty()) {
            pendingIntentFiles[fingerprint] = captured.toMutableList()
        }
        persistPendingFiles()
        if (captured.isNotEmpty()) shareEventSink?.success(captured)
    }

    /**
     * Copies a shared URI without ever reading more than the per-file or
     * remaining batch budget. Some providers do not expose a size in their
     * metadata, so the stream itself is still checked while it is copied.
     */
    private fun copyUriBounded(uri: Uri, destination: File, remainingBytes: Long): CopyResult {
        val knownSize = queryUriSize(uri)
        if (knownSize != null && knownSize > MAX_SHARED_FILE_BYTES) {
            return CopyResult(
                0L,
                "分享文件超过单文件限制 ${formatBytes(MAX_SHARED_FILE_BYTES)}，已跳过",
            )
        }
        if (knownSize != null && knownSize > remainingBytes) {
            return CopyResult(
                0L,
                "分享文件总大小超过 ${formatBytes(MAX_SHARED_TOTAL_BYTES)}，已跳过超出部分",
            )
        }
        val streamLimit = minOf(MAX_SHARED_FILE_BYTES, remainingBytes)
        if (streamLimit <= 0L) {
            return CopyResult(0L, "分享文件总大小超过 ${formatBytes(MAX_SHARED_TOTAL_BYTES)}")
        }
        var copied = 0L
        return try {
            val input = contentResolver.openInputStream(uri)
                ?: return CopyResult(0L, "无法读取分享文件")
            input.use { source ->
                destination.outputStream().use { output ->
                    val buffer = ByteArray(SHARE_COPY_BUFFER_BYTES)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        if (count == 0) continue
                        if (copied > streamLimit - count.toLong()) {
                            return CopyResult(
                                0L,
                                if (copied >= MAX_SHARED_FILE_BYTES) {
                                    "分享文件超过单文件限制 ${formatBytes(MAX_SHARED_FILE_BYTES)}，已跳过"
                                } else {
                                    "分享文件总大小超过 ${formatBytes(MAX_SHARED_TOTAL_BYTES)}，已跳过超出部分"
                                },
                            )
                        }
                        output.write(buffer, 0, count)
                        copied += count
                    }
                }
            }
            if (copied == 0L) CopyResult(0L, "分享文件为空，已跳过")
            else CopyResult(copied)
        } catch (error: Throwable) {
            CopyResult(0L, "无法读取分享文件：${error.message ?: "未知错误"}")
        }
    }

    private fun queryUriSize(uri: Uri): Long? {
        var cursor: Cursor? = null
        return try {
            cursor = contentResolver.query(
                uri,
                arrayOf(OpenableColumns.SIZE),
                null,
                null,
                null,
            )
            if (cursor != null && cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && !cursor.isNull(index)) {
                    cursor.getLong(index).takeIf { it >= 0L }
                } else {
                    // Providers commonly use -1 to mean that the size is
                    // unknown. Let the bounded stream check handle it.
                    null
                }
            } else {
                null
            }
        } catch (_: Throwable) {
            null
        } finally {
            cursor?.close()
        }
    }

    private fun recordShareError(message: String) {
        if (message.isBlank()) return
        pendingShareErrors.add(message)
        if (pendingShareErrors.size > MAX_SHARE_ERRORS) {
            pendingShareErrors.removeAt(0)
        }
    }

    private fun formatBytes(bytes: Long): String {
        val megabytes = bytes / (1024L * 1024L)
        return "${megabytes}MiB"
    }

    private fun safeShareExtension(uri: Uri): String {
        val candidate = contentResolver.getType(uri)
            ?.substringAfterLast('/')
            ?.lowercase()
            ?.takeIf { it.matches(Regex("[a-z0-9]{1,10}")) }
        return candidate ?: "bin"
    }

    private fun intentFingerprint(source: Intent, uris: List<Uri>): String {
        val parts = listOf(
            source.action.orEmpty(),
            source.type.orEmpty(),
            source.data?.toString().orEmpty(),
            uris.distinct().map(Uri::toString).sorted().joinToString("\u001f"),
        )
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(parts.joinToString("\u001e").toByteArray(Charsets.UTF_8))
        return digest.joinToString("") { byte ->
            "%02x".format(byte.toInt() and 0xff)
        }
    }

    private fun loadPendingFiles() {
        if (pendingFilesLoaded) return
        pendingFilesLoaded = true
        val encoded = pendingFilePreferences.getString(PENDING_FILES_KEY, null)
        if (!encoded.isNullOrBlank()) {
            runCatching {
                val files = JSONArray(encoded)
                for (index in 0 until files.length()) {
                    files.optString(index).takeIf { it.isNotBlank() }?.let {
                        pendingFiles.add(it)
                    }
                }
            }
        }
        val intents = pendingFilePreferences.getString(PENDING_INTENTS_KEY, null)
        if (!intents.isNullOrBlank()) {
            runCatching {
                val mappings = JSONObject(intents)
                val keys = mappings.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    val files = mappings.optJSONArray(key) ?: continue
                    val paths = mutableListOf<String>()
                    for (index in 0 until files.length()) {
                        files.optString(index).takeIf { it.isNotBlank() }?.let(paths::add)
                    }
                    if (paths.isNotEmpty()) pendingIntentFiles[key] = paths
                }
            }
        }
        val errors = pendingFilePreferences.getString(PENDING_ERRORS_KEY, null)
        if (!errors.isNullOrBlank()) {
            runCatching {
                val values = JSONArray(errors)
                for (index in 0 until values.length()) {
                    values.optString(index).takeIf { it.isNotBlank() }?.let {
                        pendingShareErrors.add(it)
                    }
                }
            }
        }
    }

    private fun persistPendingFiles() {
        val encoded = JSONArray().apply {
            pendingFiles.distinct().forEach { put(it) }
        }.toString()
        val mappings = JSONObject()
        pendingIntentFiles.forEach { (key, files) ->
            val valid = files.filter { pendingFiles.contains(it) }
            if (valid.isNotEmpty()) {
                mappings.put(key, JSONArray(valid))
            }
        }
        pendingFilePreferences.edit()
            .putString(PENDING_FILES_KEY, encoded)
            .putString(PENDING_INTENTS_KEY, mappings.toString())
            .putString(PENDING_ERRORS_KEY, JSONArray(pendingShareErrors).toString())
            .commit()
    }

    private fun acknowledgeSharedFiles(files: List<String>) {
        loadPendingFiles()
        if (files.isEmpty()) return
        pendingFiles.removeAll(files.toSet())
        pendingIntentFiles.entries.removeIf { (_, paths) ->
            paths.removeAll(files.toSet())
            paths.isEmpty()
        }
        persistPendingFiles()
    }

    private fun copyToClipboard(filePath: String): Boolean {
        val file = File(filePath)
        if (!file.exists() || file.length() <= 0L || file.length() > MAX_SHARED_FILE_BYTES) {
            return false
        }
        return runCatching {
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newUri(contentResolver, "sticker", uri))
            true
        }.getOrDefault(false)
    }

    private data class CopyResult(val bytes: Long, val error: String? = null)

    companion object {
        private const val SHARE_PREFERENCES = "sticker_manager_share_queue"
        private const val PENDING_FILES_KEY = "pending_files"
        private const val PENDING_INTENTS_KEY = "pending_intents"
        private const val PENDING_ERRORS_KEY = "pending_errors"
        private const val MAX_SHARED_FILE_BYTES = 64L * 1024L * 1024L
        private const val MAX_SHARED_TOTAL_BYTES = 512L * 1024L * 1024L
        private const val SHARE_COPY_BUFFER_BYTES = 64 * 1024
        private const val MAX_SHARE_ERRORS = 128
    }
}
