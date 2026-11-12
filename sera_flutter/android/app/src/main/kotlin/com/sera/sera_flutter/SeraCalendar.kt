package com.sera.sera_flutter

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.CalendarContract as Contract
import org.json.JSONObject
import java.security.MessageDigest
import java.util.TimeZone

internal class SeraPlatformFailure(val code: String, message: String) : Exception(message)

internal object SeraScope {
    fun prefs(context: Context) = context.getSharedPreferences("sera_platform", Context.MODE_PRIVATE)
    fun current(context: Context): String = prefs(context).getString("activeScope", "signed-out")!!
    fun hash(value: String): String = MessageDigest.getInstance("SHA-256").digest(value.toByteArray()).joinToString("") { "%02x".format(it) }
}

internal class SeraCalendar(private val context: Context, private val scope: String) {
    private val resolver get() = context.contentResolver
    private val account get() = "sera:$scope"
    private val key get() = "calendarMappings:$scope"
    private fun permission() {
        if (scope != SeraScope.current(context)) throw SeraPlatformFailure("stale_account", "账户已切换，请重新打开设备日历。")
        if (context.checkSelfPermission(Manifest.permission.READ_CALENDAR) != PackageManager.PERMISSION_GRANTED ||
            context.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) != PackageManager.PERMISSION_GRANTED)
            throw SeraPlatformFailure("calendar_denied", "尚未获得日历读写权限，请授权后重试。")
        if (context.packageManager.resolveContentProvider(Contract.AUTHORITY, 0) == null)
            throw SeraPlatformFailure("calendar_unavailable", "这台设备没有可用的 Calendar Provider，无法读取或写入系统日历。")
    }
    fun calendars(): List<Map<String, Any>> {
        permission()
        val result = mutableListOf<Map<String, Any>>()
        val projection = arrayOf(Contract.Calendars._ID, Contract.Calendars.CALENDAR_DISPLAY_NAME,
            Contract.Calendars.ACCOUNT_NAME, Contract.Calendars.CALENDAR_ACCESS_LEVEL, Contract.Calendars.ACCOUNT_TYPE)
        resolver.query(Contract.Calendars.CONTENT_URI, projection, null, null, Contract.Calendars.CALENDAR_DISPLAY_NAME)?.use { cursor ->
            while (cursor.moveToNext()) {
                val name = cursor.getString(2) ?: ""
                if (name.startsWith("sera:") && name != account) continue
                result.add(mapOf("id" to cursor.getLong(0).toString(), "name" to (cursor.getString(1) ?: "未命名日历"),
                    "account" to name, "writable" to (cursor.getInt(3) >= Contract.Calendars.CAL_ACCESS_CONTRIBUTOR),
                    "isSera" to (name == account && cursor.getString(4) == Contract.ACCOUNT_TYPE_LOCAL)))
            }
        } ?: throw SeraPlatformFailure("calendar_query_failed", "系统日历没有返回可读取的数据。")
        return result
    }
    fun ensureCalendar(): Map<String, Any> {
        calendars().firstOrNull { it["isSera"] == true }?.let { return it }
        val values = ContentValues().apply {
            put(Contract.Calendars.ACCOUNT_NAME, account); put(Contract.Calendars.ACCOUNT_TYPE, Contract.ACCOUNT_TYPE_LOCAL)
            put(Contract.Calendars.NAME, "sera-$scope"); put(Contract.Calendars.CALENDAR_DISPLAY_NAME, "SERA 序日")
            put(Contract.Calendars.CALENDAR_COLOR, 0xff28705c.toInt()); put(Contract.Calendars.CALENDAR_ACCESS_LEVEL, Contract.Calendars.CAL_ACCESS_OWNER)
            put(Contract.Calendars.OWNER_ACCOUNT, account); put(Contract.Calendars.VISIBLE, 1); put(Contract.Calendars.SYNC_EVENTS, 1)
            put(Contract.Calendars.CALENDAR_TIME_ZONE, TimeZone.getDefault().id)
        }
        val uri = Contract.Calendars.CONTENT_URI.buildUpon().appendQueryParameter(Contract.CALLER_IS_SYNCADAPTER, "true")
            .appendQueryParameter(Contract.Calendars.ACCOUNT_NAME, account).appendQueryParameter(Contract.Calendars.ACCOUNT_TYPE, Contract.ACCOUNT_TYPE_LOCAL).build()
        val inserted = resolver.insert(uri, values) ?: throw SeraPlatformFailure("calendar_create_failed", "系统拒绝创建 SERA 日历。部分设备不允许应用创建本地日历。")
        val id = ContentUris.parseId(inserted).toString()
        return mapOf("id" to id, "name" to "SERA 序日", "account" to account, "writable" to true, "isSera" to true)
    }
    fun busyEvents(ids: List<String>, start: Long, end: Long): List<Map<String, Any>> {
        permission()
        if (end <= start || end - start > 366L * 86400000) throw SeraPlatformFailure("invalid_range", "日历读取范围必须在一年以内，且结束晚于开始。")
        val allowed = calendars().filter { it["isSera"] != true }.map { it["id"].toString() }.toSet()
        val selected = ids.distinct().filter { it in allowed }.mapNotNull { it.toLongOrNull() }
        if (selected.isEmpty()) return emptyList()
        val uri = Contract.Instances.CONTENT_URI.buildUpon().also { ContentUris.appendId(it, start); ContentUris.appendId(it, end) }.build()
        val projection = arrayOf(Contract.Instances.EVENT_ID, Contract.Instances.CALENDAR_ID, Contract.Instances.TITLE,
            Contract.Instances.BEGIN, Contract.Instances.END, Contract.Instances.ALL_DAY, Contract.Instances.EVENT_LOCATION)
        val where = "${Contract.Instances.CALENDAR_ID} IN (${selected.joinToString(",") { "?" }}) AND " +
            "(${Contract.Instances.STATUS} IS NULL OR ${Contract.Instances.STATUS} != ?) AND (${Contract.Instances.AVAILABILITY} IS NULL OR ${Contract.Instances.AVAILABILITY} != ?)"
        val args = (selected.map { it.toString() } + Contract.Events.STATUS_CANCELED.toString() + Contract.Events.AVAILABILITY_FREE.toString()).toTypedArray()
        val result = mutableListOf<Map<String, Any>>()
        resolver.query(uri, projection, where, args, Contract.Instances.BEGIN)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (result.size >= 5000) throw SeraPlatformFailure("too_many_events", "选定范围超过 5000 项日程，请缩小日期范围。")
                val allDay = cursor.getInt(5) == 1
                // ALL_DAY BEGIN/END are UTC-midnight dates. Dart preserves
                // these dates independently of the device's current zone.
                val begin = cursor.getLong(3)
                val finish = cursor.getLong(4)
                if (finish <= begin) continue
                val calendarId = cursor.getLong(1).toString()
                result.add(mapOf("id" to "external:$calendarId:${cursor.getLong(0)}:$begin", "calendarId" to calendarId,
                    "title" to (cursor.getString(2) ?: "忙碌"), "start" to begin, "end" to finish,
                    "allDay" to allDay, "place" to (cursor.getString(6) ?: "")))
            }
        } ?: throw SeraPlatformFailure("calendar_read_failed", "系统拒绝读取选定日历的忙碌事件。")
        return result
    }
    private fun fingerprint(entry: Map<String, Any?>): String = SeraScope.hash(org.json.JSONArray(listOf(
        entry["title"]?.toString() ?: "", (entry["start"] as Number).toLong(), (entry["end"] as Number).toLong(),
        entry["place"]?.toString() ?: "", entry["notes"]?.toString() ?: "", entry["allDay"] == true,
        entry["timeZone"]?.toString() ?: TimeZone.getDefault().id)).toString())
    private fun marker(id: String) = "sera://calendar/$scope/${Uri.encode(id)}"
    private data class DeviceEvent(val eventId: Long, val sourceId: String?, val baseline: String?, val fields: Map<String, Any?>)
    private fun records(calendarId: Long): List<DeviceEvent> {
        val fields = arrayOf(Contract.Events._ID, Contract.Events.TITLE, Contract.Events.DTSTART, Contract.Events.DTEND,
            Contract.Events.EVENT_LOCATION, Contract.Events.DESCRIPTION, Contract.Events.CUSTOM_APP_URI,
            Contract.Events.ALL_DAY, Contract.Events.EVENT_TIMEZONE)
        val result = mutableListOf<DeviceEvent>()
        resolver.query(Contract.Events.CONTENT_URI, fields, "${Contract.Events.CALENDAR_ID} = ? AND ${Contract.Events.DELETED} = 0",
            arrayOf(calendarId.toString()), null)?.use { cursor ->
            while (cursor.moveToNext()) {
                if (result.size >= 10000) throw SeraPlatformFailure("too_many_events", "SERA 日历超过 10000 项，请先缩小同步内容。")
                val uri = cursor.getString(6)?.let { runCatching { Uri.parse(it) }.getOrNull() }
                val sourceId = if (uri?.scheme == "sera" && uri.host == "calendar" && uri.pathSegments.firstOrNull() == scope) uri.pathSegments.getOrNull(1) else null
                result.add(DeviceEvent(cursor.getLong(0), sourceId, uri?.getQueryParameter("baseline"), mapOf(
                    "title" to (cursor.getString(1) ?: ""), "start" to cursor.getLong(2), "end" to cursor.getLong(3),
                    "place" to (cursor.getString(4) ?: ""), "notes" to (cursor.getString(5) ?: ""),
                    "allDay" to (cursor.getInt(7) == 1), "timeZone" to (cursor.getString(8) ?: TimeZone.getDefault().id))))
            }
        } ?: throw SeraPlatformFailure("calendar_read_failed", "无法读取 SERA 日历来核对同步基线。")
        return result
    }
    fun sync(entries: List<Map<String, Any?>>, deleteMissing: Boolean, overwriteConflicts: Boolean = false): List<Map<String, Any?>> {
        permission()
        if (scope != SeraScope.current(context)) throw SeraPlatformFailure("stale_account", "账户已切换，请重新同步。")
        val calendarId = ensureCalendar()["id"].toString().toLong()
        val mappings = JSONObject(SeraScope.prefs(context).getString(key, "{}") ?: "{}")
        val device = records(calendarId)
        val tagged = device.filter { it.sourceId != null }.groupBy { it.sourceId!! }
        val byId = device.associateBy { it.eventId }
        val duplicates = tagged.filterValues { it.size > 1 }.keys
        val desired = entries.map { it["id"].toString() }.toSet()
        val results = mutableListOf<Map<String, Any?>>()
        fun persist() {
            if (!SeraScope.prefs(context).edit().putString(key, mappings.toString()).commit())
                throw SeraPlatformFailure("mapping_save_failed", "设备事项已处理，但本地同步映射保存失败；再次同步会通过稳定标记恢复。")
        }
        // Recover provider-side markers after process death or preference loss.
        for ((id, values) in tagged) if (!mappings.has(id)) {
            // Remember duplicate groups as pending work as well: otherwise a
            // lost mapping could make orphaned duplicates disappear from the
            // deletion report. Mutation still refuses every duplicate group.
            val value = values.first()
            mappings.put(id, JSONObject().put("eventId", value.eventId).put("fingerprint", value.baseline).put("formatVersion", 3))
        }
        persist()
        fun locate(id: String): DeviceEvent? = tagged[id]?.singleOrNull() ?: mappings.optJSONObject(id)?.let { byId[it.optLong("eventId", -1)] }
        for (entry in entries) {
            val id = entry["id"].toString(); var operation = "insert"
            try {
                if (scope != SeraScope.current(context)) throw SeraPlatformFailure("stale_account", "账户已切换，停止旧账户同步。")
                if (id.isBlank() || listOf("external:", "device:", "ics-").any { id.startsWith(it) }) throw SeraPlatformFailure("invalid_entry", "外部忙碌事项不能反向写入 SERA 日历。")
                if (id in duplicates) throw SeraPlatformFailure("duplicate_device_events", "系统日历存在相同 SERA 标记的重复事项，请先在系统日历中处理重复项。")
                val start = (entry["start"] as Number).toLong(); val end = (entry["end"] as Number).toLong()
                if (end <= start) throw SeraPlatformFailure("invalid_entry", "日程结束必须晚于开始。")
                val allDay = entry["allDay"] == true
                val timeZone = entry["timeZone"]?.toString() ?: TimeZone.getDefault().id
                if (timeZone !in TimeZone.getAvailableIDs()) throw SeraPlatformFailure("invalid_time_zone", "系统日程时区无效。")
                if (allDay && (timeZone != "UTC" || start % 86400000L != 0L || end % 86400000L != 0L))
                    throw SeraPlatformFailure("invalid_all_day", "系统全天事项必须使用 UTC 午夜日期与排他结束日期。")
                val wanted = fingerprint(entry)
                val old = locate(id)
                val actual = old?.let { fingerprint(it.fields) }
                val baseline = old?.baseline ?: mappings.optJSONObject(id)?.takeIf { it.optInt("formatVersion") >= 2 }?.optString("fingerprint")
                if (old != null) {
                    operation = "update"
                    if (actual == wanted && old.baseline == wanted) {
                        mappings.put(id, JSONObject().put("eventId", old.eventId).put("fingerprint", wanted).put("formatVersion", 3)); persist()
                        results.add(mapOf("sourceId" to id, "operation" to "unchanged", "success" to true, "deviceEventId" to old.eventId.toString())); continue
                    }
                    if (actual != wanted && (baseline.isNullOrBlank() || actual != baseline) && !overwriteConflicts)
                        throw SeraPlatformFailure("external_conflict", "系统日历已在外部修改；已保留设备内容。确认后可选择以应用内容覆盖系统改动。")
                }
                val values = ContentValues().apply {
                    put(Contract.Events.CALENDAR_ID, calendarId); put(Contract.Events.TITLE, entry["title"]?.toString() ?: "")
                    put(Contract.Events.DTSTART, start); put(Contract.Events.DTEND, end); put(Contract.Events.EVENT_TIMEZONE, timeZone)
                    put(Contract.Events.ALL_DAY, if (allDay) 1 else 0)
                    put(Contract.Events.DESCRIPTION, entry["notes"]?.toString() ?: ""); put(Contract.Events.EVENT_LOCATION, entry["place"]?.toString() ?: "")
                    put(Contract.Events.STATUS, Contract.Events.STATUS_CONFIRMED); put(Contract.Events.AVAILABILITY, Contract.Events.AVAILABILITY_BUSY)
                    put(Contract.Events.HAS_ALARM, 0); put(Contract.Events.CUSTOM_APP_PACKAGE, context.packageName)
                    put(Contract.Events.CUSTOM_APP_URI, Uri.parse(marker(id)).buildUpon().appendQueryParameter("baseline", wanted).appendQueryParameter("format", "3").build().toString())
                }
                val eventId = if (old != null) {
                    if (resolver.update(Contract.Events.CONTENT_URI, values,
                        "${Contract.Events._ID} = ? AND ${Contract.Events.CALENDAR_ID} = ?", arrayOf(old.eventId.toString(), calendarId.toString())) != 1) throw SeraPlatformFailure("event_update_failed", "系统日历更新返回失败。")
                    old.eventId
                } else {
                    val uri = resolver.insert(Contract.Events.CONTENT_URI, values) ?: throw SeraPlatformFailure("event_insert_failed", "系统日历没有保存该事项。")
                    ContentUris.parseId(uri)
                }
                mappings.put(id, JSONObject().put("eventId", eventId).put("fingerprint", wanted).put("formatVersion", 3)); persist()
                results.add(mapOf("sourceId" to id, "operation" to operation, "success" to true, "deviceEventId" to eventId.toString()))
            } catch (error: Exception) { results.add(mapOf("sourceId" to id, "operation" to operation, "success" to false, "error" to (error.message ?: "日程同步失败"))) }
        }
        if (deleteMissing) for (id in mappings.keys().asSequence().toList().filter { it !in desired }) {
            try {
                if (scope != SeraScope.current(context)) throw SeraPlatformFailure("stale_account", "账户已切换，停止旧账户同步。")
                if (id in duplicates) throw SeraPlatformFailure("duplicate_device_events", "系统存在重复标记，未自动删除。")
                val old = locate(id)
                if (old != null) {
                    val baseline = old.baseline ?: mappings.optJSONObject(id)?.takeIf { it.optInt("formatVersion") >= 2 }?.optString("fingerprint")
                    if ((baseline.isNullOrBlank() || fingerprint(old.fields) != baseline) && !overwriteConflicts)
                        throw SeraPlatformFailure("external_delete_conflict", "待删除事项已在系统日历中修改；确认覆盖系统改动后才能删除。")
                    if (resolver.delete(Contract.Events.CONTENT_URI, "${Contract.Events._ID} = ? AND ${Contract.Events.CALENDAR_ID} = ?", arrayOf(old.eventId.toString(), calendarId.toString())) != 1)
                        throw SeraPlatformFailure("event_delete_failed", "系统日历没有删除该事项，请重试。")
                }
                val eventId = mappings.optJSONObject(id)?.optLong("eventId")
                mappings.remove(id); persist()
                results.add(mapOf("sourceId" to id, "operation" to "delete", "success" to true, "deviceEventId" to eventId?.toString()))
            } catch (error: Exception) { results.add(mapOf("sourceId" to id, "operation" to "delete", "success" to false, "error" to (error.message ?: "删除同步失败"))) }
        }
        return results
    }
}
