package com.sera.sera_flutter

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.TimeZone

internal object SeraNotifications {
    private const val CHANNEL = "sera_task_reminders"
    private fun key(scope: String) = "notifications:$scope"
    private fun prefs(context: Context) = SeraScope.prefs(context)
    private fun manager(context: Context) = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    private fun alarms(context: Context) = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
    fun allowed(context: Context): Boolean = (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) && manager(context).areNotificationsEnabled()
    fun exact(context: Context): Boolean = Build.VERSION.SDK_INT < 31 || alarms(context).canScheduleExactAlarms()
    fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT >= 26) manager(context).createNotificationChannel(NotificationChannel(CHANNEL, "任务开始提醒", NotificationManager.IMPORTANCE_DEFAULT).apply {
            description = "你确认的任务开始提醒，遵守应用免打扰时段。"
        })
    }
    private fun pending(context: Context, scope: String, id: String, version: String = ""): PendingIntent {
        val intent = Intent(context, SeraReminderReceiver::class.java).apply {
            action = "com.sera.REMINDER"
            data = Uri.parse("sera://reminder/${Uri.encode(scope)}/${Uri.encode(id)}")
            putExtra("scope", scope); putExtra("id", id)
            putExtra("version", version)
        }
        return PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    }
    private fun stored(context: Context, scope: String): JSONArray = try { JSONArray(prefs(context).getString(key(scope), "[]")) } catch (_: Exception) { JSONArray() }
    fun list(context: Context, scope: String): List<Map<String, Any?>> {
        val values = stored(context, scope)
        return (0 until values.length()).map { index -> val value = values.getJSONObject(index)
            value.keys().asSequence().associateWith { value.opt(it) } }
    }
    fun cancel(context: Context, scope: String, clear: Boolean = true) {
        val values = stored(context, scope)
        for (i in 0 until values.length()) {
            val id = values.getJSONObject(i).getString("id")
            alarms(context).cancel(pending(context, scope, id)); manager(context).cancel("$scope:$id", 1)
        }
        manager(context).cancel("$scope:test", 1)
        if (clear) prefs(context).edit().remove(key(scope)).apply()
    }
    private fun arm(context: Context, scope: String, value: JSONObject) {
        val trigger = value.getLong("fireAt")
        if (trigger <= System.currentTimeMillis()) return
        val operation = pending(context, scope, value.getString("id"), value.optString("version"))
        if (exact(context)) alarms(context).setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, operation)
        else alarms(context).setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, operation)
    }
    fun schedule(context: Context, scope: String, requests: List<Map<String, Any?>>, enabled: Boolean, quietStart: Int, quietEnd: Int, revision: Long = 0L, timeZone: String = TimeZone.getDefault().id): Map<String, Any> {
        if (scope != SeraScope.current(context)) throw SeraPlatformFailure("stale_account", "账户已切换，请在当前账户重新安排提醒。")
        if (quietStart !in 0..1439 || quietEnd !in 0..1439) throw SeraPlatformFailure("invalid_quiet_hours", "免打扰时段无效。")
        if (timeZone !in TimeZone.getAvailableIDs()) throw SeraPlatformFailure("invalid_time_zone", "提醒时区无效。")
        val generation = maxOf(revision, requests.mapNotNull { (it["generation"] as? Number)?.toLong() }.maxOrNull() ?: 0L)
        if (generation < prefs(context).getLong("notificationGeneration:$scope", 0L))
            throw SeraPlatformFailure("stale_generation", "已有更新的提醒安排，本次旧版本未覆盖现有提醒。")
        cancel(context, scope)
        prefs(context).edit().putInt("quietStart:$scope", quietStart).putInt("quietEnd:$scope", quietEnd).putBoolean("notificationsEnabled:$scope", enabled)
            .putLong("notificationGeneration:$scope", generation).putString("notificationTimeZone:$scope", timeZone).apply()
        if (!enabled) return mapOf("scheduled" to 0, "skipped" to requests.size, "exact" to exact(context), "errors" to emptyList<String>())
        if (!allowed(context)) throw SeraPlatformFailure("notification_denied", "系统通知权限或应用通知开关未开启，尚未安排本地通知。")
        ensureChannel(context)
        if (Build.VERSION.SDK_INT >= 26 && manager(context).getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE)
            throw SeraPlatformFailure("notification_channel_denied", "任务提醒通知渠道已被关闭，请在系统应用通知设置中开启。")
        val successes = JSONArray(); val errors = mutableListOf<String>(); var skipped = 0
        for (request in requests) {
            try {
                val value = JSONObject(request)
                value.put("version", SeraScope.hash("$scope:${value.optString("id")}:${value.optLong("fireAt")}:${value.optLong("generation")}"))
                if (value.getString("id").isBlank()) throw SeraPlatformFailure("invalid_reminder", "提醒缺少任务编号。")
                if (value.getLong("fireAt") <= System.currentTimeMillis()) { skipped++; continue }
                arm(context, scope, value); successes.put(value)
            } catch (error: Exception) { errors.add("${request["title"] ?: request["id"]}: ${error.message ?: "安排提醒失败"}") }
        }
        prefs(context).edit().putString(key(scope), successes.toString()).apply()
        return mapOf("scheduled" to successes.length(), "skipped" to skipped, "exact" to exact(context), "errors" to errors,
            "warnings" to if (exact(context)) emptyList<String>() else listOf("未开启精确闹钟权限，系统使用允许休眠的非精确提醒，可能延迟。"))
    }
    fun reschedule(context: Context) {
        val scope = SeraScope.current(context)
        if (!allowed(context) || !prefs(context).getBoolean("notificationsEnabled:$scope", false)) return
        ensureChannel(context)
        val values = stored(context, scope); val remaining = JSONArray()
        for (i in 0 until values.length()) {
            val value = values.getJSONObject(i)
            if (value.optLong("fireAt") > System.currentTimeMillis()) {
                try { arm(context, scope, value); remaining.put(value) }
                catch (error: Exception) { prefs(context).edit().putString("notificationRescheduleError:$scope", error.message).apply(); remaining.put(value) }
            }
        }
        prefs(context).edit().putString(key(scope), remaining.toString()).apply()
    }
    private fun quiet(context: Context, scope: String): Boolean {
        val start = prefs(context).getInt("quietStart:$scope", 1320); val end = prefs(context).getInt("quietEnd:$scope", 480)
        val now = Calendar.getInstance(TimeZone.getTimeZone(prefs(context).getString("notificationTimeZone:$scope", TimeZone.getDefault().id)))
        val minute = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        return if (start == end) false else if (start < end) minute >= start && minute < end else minute >= start || minute < end
    }
    fun deliver(context: Context, scope: String, id: String, version: String) {
        if (scope != SeraScope.current(context)) return
        val values = stored(context, scope); val remaining = JSONArray(); var selected: JSONObject? = null
        for (i in 0 until values.length()) {
            val value = values.getJSONObject(i)
            if (value.optString("id") == id && value.optString("version") == version) selected = value else remaining.put(value)
        }
        if (selected == null) return
        prefs(context).edit().putString(key(scope), remaining.toString()).apply()
        if (!allowed(context) || !prefs(context).getBoolean("notificationsEnabled:$scope", false) || quiet(context, scope) ||
            (selected.optLong("validUntil", Long.MAX_VALUE) <= System.currentTimeMillis())) {
            prefs(context).edit().putString("notificationDelivery:$scope", "提醒被权限、全局开关或免打扰时段抑制：$id").apply(); return
        }
        show(context, scope, id, selected.getString("title"), selected.optString("body"), selected.optString("route", "/27"))
        prefs(context).edit().putString("notificationDelivery:$scope", "已展示任务提醒：$id").apply()
    }
    fun showTest(context: Context, scope: String) {
        if (!allowed(context)) throw SeraPlatformFailure("notification_denied", "系统通知尚未开启，请授权后重试。")
        ensureChannel(context)
        if (Build.VERSION.SDK_INT >= 26 && manager(context).getNotificationChannel(CHANNEL)?.importance == NotificationManager.IMPORTANCE_NONE)
            throw SeraPlatformFailure("notification_channel_denied", "任务提醒通知渠道已被关闭。")
        // Explicit foreground test is labelled and does not alter scheduled reminders.
        show(context, scope, "test", "SERA 通知测试", "这是一条实际 Android 本地通知；任务定时提醒会遵守免打扰设置。", "/27")
    }
    private fun show(context: Context, scope: String, id: String, title: String, body: String, requestedRoute: String) {
        ensureChannel(context)
        val route = if (Regex("^/(18|24)\\?taskId=[^#\\s]+$").matches(requestedRoute)) requestedRoute else "/27"
        val open = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            data = Uri.parse("sera://notification/${Uri.encode(scope)}/${Uri.encode(id)}")
            putExtra("scope", scope); putExtra("route", route)
        }
        val tap = PendingIntent.getActivity(context, 0, open, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(context, CHANNEL) else Notification.Builder(context)
        val notification = builder.setSmallIcon(android.R.drawable.ic_popup_reminder).setContentTitle(title).setContentText(body)
            .setStyle(Notification.BigTextStyle().bigText(body)).setContentIntent(tap).setAutoCancel(true).setCategory(Notification.CATEGORY_REMINDER).build()
        manager(context).notify("$scope:$id", 1, notification)
    }
}

class SeraReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        Thread {
            try { SeraNotifications.deliver(context.applicationContext, intent.getStringExtra("scope") ?: "", intent.getStringExtra("id") ?: "", intent.getStringExtra("version") ?: "") }
            catch (error: Exception) { SeraScope.prefs(context).edit().putString("lastNotificationError", error.message).apply() }
            finally { pending.finish() }
        }.start()
    }
}
class SeraBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in setOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED,
            "android.app.action.SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED")) return
        val pending = goAsync()
        Thread {
            try { SeraNotifications.reschedule(context.applicationContext) }
            catch (error: Exception) { SeraScope.prefs(context).edit().putString("lastNotificationError", error.message).apply() }
            finally { pending.finish() }
        }.start()
    }
}
