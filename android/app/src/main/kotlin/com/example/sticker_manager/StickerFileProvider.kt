package com.example.sticker_manager

import android.net.Uri
import androidx.core.content.FileProvider

class StickerFileProvider : FileProvider() {
    override fun getType(uri: Uri): String? {
        val name = uri.lastPathSegment?.lowercase() ?: return super.getType(uri)
        return when {
            name.endsWith(".gif") -> "image/gif"
            name.endsWith(".png") -> "image/png"
            name.endsWith(".jpg") || name.endsWith(".jpeg") -> "image/jpeg"
            name.endsWith(".webp") -> "image/webp"
            name.endsWith(".bmp") -> "image/bmp"
            name.endsWith(".image") -> "image/*"
            else -> super.getType(uri)
        }
    }
}
