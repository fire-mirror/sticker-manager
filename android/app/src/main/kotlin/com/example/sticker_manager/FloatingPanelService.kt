package com.example.sticker_manager

import android.app.Service
import android.app.NotificationChannel
import android.app.NotificationManager
import android.os.Build
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.HorizontalScrollView
import android.widget.ImageButton
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.FileProvider
import androidx.core.app.NotificationCompat
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class FloatingPanelService : Service() {
    private lateinit var windowManager: WindowManager
    private var bubble: View? = null
    private var panel: View? = null

    override fun onCreate() {
        super.onCreate()
        if (!Settings.canDrawOverlays(this)) {
            cancelStartRequest()
            stopSelf()
            return
        }
        val shouldStop = synchronized(lifecycleLock) {
            if (stopRequested) {
                stopRequested = false
                startRequested = false
                true
            } else {
                startRequested = false
                running = true
                instance = this
                false
            }
        }
        if (shouldStop) {
            stopSelf()
            return
        }
        try {
            windowManager = getSystemService(WINDOW_SERVICE) as WindowManager
            startAsForegroundService()
            createBubble()
            reloadStickers()
        } catch (error: Throwable) {
            hidePanel()
            bubble?.let { runCatching { windowManager.removeView(it) } }
            bubble = null
            synchronized(lifecycleLock) {
                instance = null
                running = false
                startRequested = false
            }
            stopSelf()
            throw error
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (!Settings.canDrawOverlays(this)) {
            stopSelfResult(startId)
            return START_NOT_STICKY
        }
        reloadStickers()
        return START_STICKY
    }

    override fun onDestroy() {
        hidePanel()
        bubble?.let { runCatching { windowManager.removeView(it) } }
        bubble = null
        synchronized(lifecycleLock) {
            instance = null
            running = false
            startRequested = false
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun createBubble() {
        val button = ImageButton(this).apply {
            contentDescription = "打开表情面板"
            setImageResource(android.R.drawable.ic_menu_gallery)
            setColorFilter(Color.WHITE)
            background = roundedBackground(0xff0f766e.toInt(), 48f)
            setPadding(12, 12, 12, 12)
            setOnClickListener { togglePanel() }
        }
        bubble = button
        windowManager.addView(button, overlayParams(56, 56))
    }

    private fun startAsForegroundService() {
        val channelId = "floating_panel"
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "悬浮面板",
                NotificationManager.IMPORTANCE_LOW,
            )
            val notifications = getSystemService(NotificationManager::class.java)
            notifications.createNotificationChannel(channel)
        }
        val notification = NotificationCompat.Builder(this, channelId)
            .setSmallIcon(android.R.drawable.ic_menu_gallery)
            .setContentTitle("表情管家")
            .setContentText("悬浮面板已开启")
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        startForeground(NOTIFICATION_ID, notification)
    }

    private fun togglePanel() {
        if (panel == null) {
            showPanel()
        } else {
            hidePanel()
        }
    }

    private fun showPanel() {
        val root = FrameLayout(this).apply {
            background = roundedBackground(0xfafafaff.toInt(), 12f)
            setPadding(8, 8, 8, 8)
        }
        val scroll = HorizontalScrollView(this).apply {
            isHorizontalScrollBarEnabled = false
        }
        val items = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
        }
        scroll.addView(items, FrameLayout.LayoutParams(-2, 76))
        root.addView(scroll, FrameLayout.LayoutParams(-2, 76))
        panel = root
        windowManager.addView(root, panelParams())
        populate(items)
    }

    private fun hidePanel() {
        val current = panel ?: return
        runCatching { windowManager.removeView(current) }
        panel = null
    }

    private fun reloadStickers() {
        val current = panel ?: return
        val scroll = current as? FrameLayout ?: return
        val horizontal = scroll.getChildAt(0) as? HorizontalScrollView ?: return
        val items = horizontal.getChildAt(0) as? LinearLayout ?: return
        populate(items)
    }

    private fun populate(container: LinearLayout) {
        container.removeAllViews()
        val stored = getSharedPreferences(PREFERENCES, MODE_PRIVATE)
            .getString(STICKERS_KEY, "[]") ?: "[]"
        val stickers = runCatching { JSONArray(stored) }.getOrElse { JSONArray() }
        var displayed = 0
        for (index in 0 until stickers.length()) {
            if (displayed >= MAX_ITEMS) break
            val item = stickers.optJSONObject(index) ?: continue
            val file = File(item.optString("path"))
            if (!file.exists() || file.length() == 0L) continue
            val image = ImageView(this).apply {
                contentDescription = item.optString("note", "表情")
                scaleType = ImageView.ScaleType.CENTER_CROP
                setPadding(4, 4, 4, 4)
                try {
                    setImageURI(FileProvider.getUriForFile(
                        this@FloatingPanelService,
                        "${packageName}.fileprovider",
                        file,
                    ))
                } catch (_: IllegalArgumentException) {
                    setImageURI(Uri.fromFile(file))
                }
                setOnClickListener {
                    if (copyToClipboard(file)) {
                        recordUsageEvent(this@FloatingPanelService, item.optString("id"))
                        hidePanel()
                    }
                }
            }
            container.addView(image, LinearLayout.LayoutParams(72, 72))
            displayed++
        }
        if (displayed == 0) {
            container.addView(TextView(this).apply {
                text = "暂无可用表情"
                setTextColor(0xff555555.toInt())
                gravity = Gravity.CENTER
                setPadding(16, 0, 16, 0)
            }, LinearLayout.LayoutParams(-2, 72))
        }
    }

    private fun copyToClipboard(file: File): Boolean {
        return runCatching {
            val uri = FileProvider.getUriForFile(this, "${packageName}.fileprovider", file)
            val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            clipboard.setPrimaryClip(ClipData.newUri(contentResolver, "sticker", uri))
            true
        }.getOrDefault(false)
    }

    private fun roundedBackground(color: Int, radius: Float): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = radius
        }
    }

    private fun overlayParams(width: Int, height: Int): WindowManager.LayoutParams {
        return WindowManager.LayoutParams(
            width,
            height,
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.END
            x = 16
            y = 220
        }
    }

    private fun panelParams(): WindowManager.LayoutParams {
        return overlayParams(WindowManager.LayoutParams.WRAP_CONTENT, 92).apply {
            x = 80
            y = 202
        }
    }

    companion object {
        private const val PREFERENCES = "sticker_manager_overlay"
        private const val STICKERS_KEY = "stickers"
        private const val USAGE_KEY = "pending_usage_counts"
        private const val MAX_ITEMS = 100
        private const val NOTIFICATION_ID = 2401

        @Volatile
        var running: Boolean = false
            private set

        private val lifecycleLock = Any()

        @Volatile
        private var startRequested: Boolean = false

        @Volatile
        private var stopRequested: Boolean = false

        private var instance: FloatingPanelService? = null

        /** Returns true only for the caller that must issue a service start. */
        fun requestStart(): Boolean = synchronized(lifecycleLock) {
            if (running || startRequested) return@synchronized false
            startRequested = true
            stopRequested = false
            true
        }

        fun cancelStartRequest() = synchronized(lifecycleLock) {
            startRequested = false
            stopRequested = false
        }

        fun requestStop() = synchronized(lifecycleLock) {
            startRequested = false
            stopRequested = true
        }

        fun updateStickers(context: Context, stickers: List<Map<String, Any?>>) {
            val array = JSONArray()
            stickers.take(MAX_ITEMS).forEach { item ->
                array.put(JSONObject().apply {
                    put("id", item["id"] ?: "")
                    put("path", item["path"] ?: "")
                    put("mediaType", item["mediaType"] ?: "image")
                    put("note", item["note"] ?: "")
                })
            }
            context.getSharedPreferences(PREFERENCES, MODE_PRIVATE)
                .edit()
                .putString(STICKERS_KEY, array.toString())
                .apply()
            instance?.reloadStickers()
        }

        fun recordUsageEvent(context: Context, stickerId: String) {
            if (stickerId.isBlank()) return
            synchronized(lifecycleLock) {
                val preferences = context.getSharedPreferences(PREFERENCES, MODE_PRIVATE)
                val counts = runCatching {
                    JSONObject(preferences.getString(USAGE_KEY, "{}") ?: "{}")
                }.getOrElse { JSONObject() }
                counts.put(stickerId, counts.optInt(stickerId, 0) + 1)
                preferences.edit().putString(USAGE_KEY, counts.toString()).commit()
            }
        }

        fun peekUsageEvents(context: Context): List<String> {
            synchronized(lifecycleLock) {
                val preferences = context.getSharedPreferences(PREFERENCES, MODE_PRIVATE)
                val counts = runCatching {
                    JSONObject(preferences.getString(USAGE_KEY, "{}") ?: "{}")
                }.getOrElse { JSONObject() }
                val result = mutableListOf<String>()
                val keys = counts.keys()
                while (keys.hasNext()) {
                    val stickerId = keys.next()
                    repeat(counts.optInt(stickerId, 0).coerceAtLeast(0)) {
                        result.add(stickerId)
                    }
                }
                return result
            }
        }

        fun ackUsageEvents(context: Context, ids: List<String>) {
            if (ids.isEmpty()) return
            synchronized(lifecycleLock) {
                val preferences = context.getSharedPreferences(PREFERENCES, MODE_PRIVATE)
                val counts = runCatching {
                    JSONObject(preferences.getString(USAGE_KEY, "{}") ?: "{}")
                }.getOrElse { JSONObject() }
                val consumed = ids.filter { it.isNotBlank() }.groupingBy { it }.eachCount()
                consumed.forEach { (stickerId, count) ->
                    val remaining = counts.optInt(stickerId, 0) - count
                    if (remaining > 0) {
                        counts.put(stickerId, remaining)
                    } else {
                        counts.remove(stickerId)
                    }
                }
                val editor = preferences.edit()
                if (counts.length() == 0) {
                    editor.remove(USAGE_KEY)
                } else {
                    editor.putString(USAGE_KEY, counts.toString())
                }
                editor.commit()
            }
        }
    }
}
