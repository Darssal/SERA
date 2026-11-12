package com.sera.sera_flutter

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.CalendarContract
import android.provider.DocumentsContract
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private val worker = Executors.newSingleThreadExecutor()
    private val audio by lazy { SeraAudio(applicationContext) }
    private var permissionResult: MethodChannel.Result? = null
    private var permissionKind = ""
    private var fileResult: MethodChannel.Result? = null
    private var fileContent: String? = null
    private var pendingRoute: String? = null
    private var pcmEvents: EventChannel? = null
    private var pcmSink: EventChannel.EventSink? = null
    @Volatile private var pcmActive = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sera/platform").also { bridge ->
            bridge.setMethodCallHandler { call, result -> handle(call, result) }
        }
        captureNotificationRoute(intent, false)
        pcmEvents = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.sera/audio_pcm").also { events ->
            events.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { pcmSink = sink }
                override fun onCancel(arguments: Any?) { audio.stopStream(true); pcmActive = false; pcmSink = null }
            })
        }
    }
    private fun granted(permission: String) = checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    private fun state(kind: String): String = when (kind) {
        "calendar" -> if (granted(Manifest.permission.READ_CALENDAR) && granted(Manifest.permission.WRITE_CALENDAR)) "granted" else "denied"
        "microphone" -> if (granted(Manifest.permission.RECORD_AUDIO)) "granted" else "denied"
        "notifications" -> if (SeraNotifications.allowed(this)) "granted" else "denied"
        else -> "unsupported"
    }
    private fun capabilityMap(): Map<String, Any> = mapOf(
        "platform" to "android", "calendarSupported" to (packageManager.resolveContentProvider(CalendarContract.AUTHORITY, 0) != null),
        "notificationsSupported" to true, "backgroundNotifications" to true,
        "recordingSupported" to packageManager.hasSystemFeature(PackageManager.FEATURE_MICROPHONE),
        "calendarPermission" to state("calendar"), "notificationPermission" to state("notifications"),
        "microphonePermission" to state("microphone"), "exactAlarmsSupported" to SeraNotifications.exact(this))
    private fun fail(result: MethodChannel.Result, error: Throwable) {
        if (error is SeraPlatformFailure) result.error(error.code, error.message, null)
        else if (error is SecurityException) result.error("permission_denied", "系统拒绝访问：${error.message ?: "权限不足"}", null)
        else result.error("platform_failed", error.message ?: "系统操作失败，请重试。", null)
    }
    private fun background(result: MethodChannel.Result, operation: () -> Any?) {
        worker.execute { try { val value = operation(); runOnUiThread { result.success(value) } }
            catch (error: Throwable) { runOnUiThread { fail(result, error) } } }
    }
    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        try {
            val scope = SeraScope.current(this)
            when (call.method) {
                "capabilities" -> result.success(capabilityMap())
                "setAccountScope" -> {
                    val userId = call.argument<String>("userId") ?: throw SeraPlatformFailure("invalid_account", "账户编号不能为空。")
                    val next = SeraScope.hash(userId.ifBlank { "signed-out" })
                    if (next != scope) {
                        SeraNotifications.cancel(this, scope, clear = false); audio.cancel()
                        SeraScope.prefs(this).edit().putString("activeScope", next).apply()
                        pendingRoute = null
                    }
                    result.success(null)
                }
                "consumeInitialNotificationRoute" -> { result.success(pendingRoute); pendingRoute = null }
                "requestPermission" -> requestPermission(call.argument<String>("kind") ?: "", result)
                "openApplicationSettings" -> { startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))); result.success(null) }
                "requestExactAlarmPermission" -> {
                    if (Build.VERSION.SDK_INT >= 31 && !SeraNotifications.exact(this)) startActivity(Intent(Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, Uri.parse("package:$packageName")))
                    result.success(null)
                }
                "listCalendars" -> background(result) { SeraCalendar(applicationContext, scope).calendars() }
                "ensureSeraCalendar" -> background(result) { SeraCalendar(applicationContext, scope).ensureCalendar() }
                "readBusyEvents" -> background(result) { SeraCalendar(applicationContext, scope).busyEvents(
                    call.argument<List<String>>("calendarIds") ?: emptyList(), call.argument<Number>("start")!!.toLong(), call.argument<Number>("end")!!.toLong()) }
                "syncCalendarEntries" -> background(result) { SeraCalendar(applicationContext, scope).sync(
                    call.argument<List<Map<String, Any?>>>("entries") ?: emptyList(), call.argument<Boolean>("deleteMissing") != false,
                    call.argument<Boolean>("overwriteConflicts") == true) }
                "scheduleNotifications" -> background(result) { SeraNotifications.schedule(applicationContext, scope,
                    call.argument<List<Map<String, Any?>>>("requests") ?: emptyList(), call.argument<Boolean>("enabled") == true,
                    call.argument<Number>("quietStart")?.toInt() ?: 1320, call.argument<Number>("quietEnd")?.toInt() ?: 480,
                    call.argument<Number>("generation")?.toLong() ?: 0L,
                    call.argument<String>("timeZone") ?: java.util.TimeZone.getDefault().id) }
                "scheduledNotifications" -> result.success(SeraNotifications.list(this, scope))
                "showTestNotification" -> { SeraNotifications.showTest(this, scope); result.success(null) }
                "cancelNotifications" -> { SeraNotifications.cancel(this, scope); result.success(null) }
                "startRecording" -> { audio.start(); result.success(null) }
                "stopRecording" -> background(result) { audio.stop() }
                "cancelRecording" -> background(result) { audio.cancel(); null }
                "startAudioStream" -> {
                    val sink = pcmSink ?: throw SeraPlatformFailure("audio_channel_missing", "实时音频通道尚未订阅。")
                    pcmActive = true
                    try {
                        audio.start(onPcm = { bytes -> runOnUiThread { if (pcmActive) sink.success(bytes) } },
                            onEnd = { error -> runOnUiThread {
                                pcmActive = false
                                if (error != null) sink.error("audio_stream_failed", error, null)
                                sink.endOfStream()
                            } })
                        result.success(null)
                    } catch (error: Throwable) { pcmActive = false; throw error }
                }
                "stopAudioStream" -> background(result) {
                    audio.stopStream(call.argument<Boolean>("cancel") == true)
                    pcmActive = false; null
                }
                "pickIcsFile" -> {
                    if (fileResult != null) throw SeraPlatformFailure("file_busy", "已有文件选择对话框，请先完成或取消。")
                    fileResult = result; fileContent = null
                    startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE); type = "*/*"
                        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/calendar", "text/plain", "application/octet-stream")) }, 7101)
                }
                "saveIcsFile", "saveTextFile" -> {
                    if (fileResult != null) throw SeraPlatformFailure("file_busy", "已有文件保存对话框，请先完成或取消。")
                    val content = call.argument<String>("content") ?: ""
                    if (content.toByteArray(Charsets.UTF_8).size > 10 * 1024 * 1024) throw SeraPlatformFailure("file_too_large", "导出文件不能超过 10 MiB。")
                    fileResult = result; fileContent = content
                    val filename = (call.argument<String>("filename") ?: "sera-calendar.ics").replace(Regex("[\\\\/\\x00-\\x1f]"), "_").take(120)
                    startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).apply { addCategory(Intent.CATEGORY_OPENABLE)
                        type = if (call.method == "saveIcsFile") "text/calendar" else call.argument<String>("mimeType") ?: "application/json"
                        putExtra(Intent.EXTRA_TITLE, filename) }, 7102)
                }
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            if (fileResult === result) { fileResult = null; fileContent = null }
            if (permissionResult === result) { permissionResult = null; permissionKind = "" }
            fail(result, error)
        }
    }
    private fun requestPermission(kind: String, result: MethodChannel.Result) {
        if (state(kind) == "unsupported") throw SeraPlatformFailure("unsupported", "系统不支持该权限类型。")
        if (state(kind) == "granted") { result.success("granted"); return }
        if (permissionResult != null) throw SeraPlatformFailure("permission_busy", "已有系统权限请求，请先完成。")
        val needed = when (kind) {
            "calendar" -> arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR)
            "microphone" -> arrayOf(Manifest.permission.RECORD_AUDIO)
            "notifications" -> if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray()
            else -> emptyArray()
        }.filter { !granted(it) }.toTypedArray()
        if (needed.isEmpty()) { result.success("denied"); return }
        permissionKind = kind; permissionResult = result; requestPermissions(needed, 7100)
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 7100) { permissionResult?.success(state(permissionKind)); permissionResult = null; permissionKind = "" }
    }
    @Deprecated("Android callback inherited by FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 7101 && requestCode != 7102) return
        val result = fileResult ?: return; val content = fileContent; fileResult = null; fileContent = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            if (requestCode == 7101) result.success(null) else result.error("cancelled", "已取消保存文件。", null)
            return
        }
        background(result) {
            if (requestCode == 7101) {
                val input = contentResolver.openInputStream(uri) ?: throw SeraPlatformFailure("file_read_failed", "无法打开选中的 ICS 文件。")
                input.use { stream -> val bytes = ByteArrayOutputStream(); val buffer = ByteArray(8192)
                    while (true) { val count = stream.read(buffer); if (count < 0) break; bytes.write(buffer, 0, count)
                        if (bytes.size() > 4 * 1024 * 1024) throw SeraPlatformFailure("file_too_large", "ICS 文件不能超过 4 MiB。") }
                    bytes.toString("UTF-8") }
            } else {
                try {
                    val output = contentResolver.openOutputStream(uri, "wt") ?: throw SeraPlatformFailure("file_write_failed", "无法保存到所选位置。")
                    output.use { it.write((content ?: "").toByteArray(Charsets.UTF_8)); it.flush() }; null
                } catch (error: Exception) {
                    val cleaned = runCatching { DocumentsContract.deleteDocument(contentResolver, uri) }.getOrDefault(false)
                    throw SeraPlatformFailure("file_write_failed", "文件写入失败：${error.message ?: "存储不可用"}。" +
                        if (cleaned) "已清理未完成文件。" else "无法自动清理未完成文件，请在所选位置检查并删除空文件。")
                }
            }
        }
    }
    private fun captureNotificationRoute(source: Intent?, notifyDart: Boolean) {
        val route = source?.getStringExtra("route") ?: return
        if (source.getStringExtra("scope") != SeraScope.current(this)) return
        if (!route.startsWith("/18?") && !route.startsWith("/24?") && route != "/27") return
        if (notifyDart) channel?.invokeMethod("notificationTap", route) else pendingRoute = route
        source.removeExtra("route")
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); captureNotificationRoute(intent, true) }
    override fun onResume() { super.onResume(); worker.execute { try { SeraNotifications.reschedule(applicationContext) } catch (_: Exception) {} } }
    override fun onDestroy() {
        try { audio.cancel() } catch (_: Exception) {}
        permissionResult?.error("activity_destroyed", "系统权限请求已中断，请重试。", null); permissionResult = null
        fileResult?.error("activity_destroyed", "文件选择已中断，请重试。", null); fileResult = null
        channel?.setMethodCallHandler(null); worker.shutdown(); super.onDestroy()
        pcmEvents?.setStreamHandler(null); pcmSink = null
    }
}
