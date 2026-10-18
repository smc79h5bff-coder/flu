package com.example.docdiff

import android.app.ActivityManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "docdiff/exit_info"
        ).setMethodCallHandler { call, result ->
            if (call.method == "getLastExitInfo") {
                result.success(getLastExitInfo())
            } else {
                result.notImplemented()
            }
        }
    }

    /// 查询上一次进程的退出记录（Android 11+ 的 ApplicationExitInfo）。
    /// 返回 null 表示没有记录（首次启动、被清除或系统不支持）。
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
