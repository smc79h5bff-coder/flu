package com.example.docdiff

import android.app.ActivityManager
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {

    companion object {
        private const val SHARE_CHANNEL = "docdiff/share_intent"

        /// 还没被 Flutter 取走的分享文件列表。
        /// 每个条目是 mapOf("path" to 绝对路径, "name" to 显示名)。
        @Volatile
        private var pendingShares: List<Map<String, String>> = emptyList()

        private fun Context.shareCacheDir(): File {
            val dir = File(cacheDir, "share_intent")
            if (!dir.exists()) dir.mkdirs()
            return dir
        }

        /** 清理超过 3 天的旧分享缓存。 */
        fun cleanupShareCache(ctx: Context) {
            val root = ctx.shareCacheDir()
            val cutoff = System.currentTimeMillis() - 3L * 24 * 3600 * 1000
            root.listFiles()?.forEach { f ->
                if (f.isFile && f.lastModified() < cutoff) f.delete()
            }
        }
    }

    private var shareChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // —— 退出信息查询 ——
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "docdiff/exit_info")
            .setMethodCallHandler { call, result ->
                if (call.method == "getLastExitInfo") {
                    result.success(getLastExitInfo())
                } else {
                    result.notImplemented()
                }
            }

        // —— 分享进来的文件 ——
        shareChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
        shareChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingShares" -> {
                    val out = pendingShares
                    pendingShares = emptyList()
                    result.success(out)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingIntent(intent)
    }

    /** 热启动（App 已经在栈顶）会走这里；singleTop 模式下不会新建 Activity。 */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        when (action) {
            Intent.ACTION_SEND -> {
                val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: return
                val cached = copyUriToCache(uri) ?: return
                pendingShares = listOf(cached)
                // 通知 Flutter 侧去取
                dispatchShareEvent()
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris: List<Uri> = intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    ?: intent.clipData?.let { cd ->
                        (0 until cd.itemCount).mapNotNull { cd.getItemAt(it).uri }
                    }
                    ?: return
                val copied = uris.mapNotNull { copyUriToCache(it) }
                if (copied.isNotEmpty()) {
                    pendingShares = copied
                    dispatchShareEvent()
                }
            }
        }
    }

    private fun dispatchShareEvent() {
        val channel = shareChannel ?: return
        runOnUiThread {
            channel.invokeMethod("onSharesPending", null)
        }
    }

    /** 把分享的 URI 转成一个本地可读取的临时文件。
     *  content://  → 先复制到 cache/share_intent 再返回
     *  file:// 且在 cache 内 → 直接用（防插件覆盖）
     *  file:// 且是用户真实文件 → 直接返回原路径，绝不复制
     */
    private fun copyUriToCache(uri: Uri): Map<String, String>? {
        return try {
            val resolver = contentResolver

            // 尝试 file://
            if (uri.scheme == "file" && uri.path != null) {
                val path = uri.path!!
                val name = path.substringAfterLast('/')
                val cacheRoot = cacheDir.absolutePath
                if (path.startsWith(cacheRoot)) {
                    // 已经在缓存里了，检查是不是我们自己的目录
                    if (path.contains("/share_compare/")) {
                        // 这是上一轮对比页刚生成的，不能再复制，否则路径重合
                        return mapOf("path" to path, "name" to name)
                    }
                }
                // 其他 file:// 一律复制，避免原文件被删或被同名覆盖
                val dest = copyStreamTo(uri, resolver, name) ?: return null
                return mapOf("path" to dest.absolutePath, "name" to name)
            }

            // content:// — 查显示名 + 复制
            var displayName = "shared_${System.currentTimeMillis()}"
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val dn = c.getString(0)
                    if (!dn.isNullOrEmpty()) displayName = dn
                }
            }
            val dest = copyStreamTo(uri, resolver, displayName) ?: return null
            mapOf("path" to dest.absolutePath, "name" to displayName)
        } catch (e: Exception) {
            null
        }
    }

    private fun copyStreamTo(uri: Uri, resolver: android.content.ContentResolver, name: String): File? {
        val safeName = System.currentTimeMillis().toString(16) + "_" + name
        val dest = File(shareCacheDir(), safeName)
        resolver.openInputStream(uri)?.use { input ->
            FileOutputStream(dest).use { out ->
                input.copyTo(out)
            }
        } ?: return null
        return dest
    }

    /// 查询上一次进程的退出记录（Android 11+ 的 ApplicationExitInfo）。
    private fun getLastExitInfo(): Map<String, Any>? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val am = getSystemService(ActivityManager::class.java) ?: return null
        val infos = try {
            am.getHistoricalProcessExitReasons(packageName, 0, 1)
        } catch (e: Exception) {
            null
        }
        if (infos == null || infos.isEmpty()) return null
        val info = infos[0]
        return mapOf(
            "reason" to info.reason,
            "description" to (info.description ?: ""),
            "timestamp" to info.timestamp
        )
    }
}
