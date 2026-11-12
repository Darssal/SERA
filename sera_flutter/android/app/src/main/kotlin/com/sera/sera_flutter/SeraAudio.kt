package com.sera.sera_flutter

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Base64
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/** Real 16 kHz mono PCM recording, encoded as a standards-compliant WAV file. */
internal class SeraAudio(private val context: Context) {
    private var recorder: AudioRecord? = null
    private var worker: Thread? = null
    @Volatile private var running = false
    @Volatile private var cancelled = false
    @Volatile private var failure: String? = null
    private var captured = ByteArrayOutputStream()
    @Volatile private var streaming = false
    fun start(onPcm: ((ByteArray) -> Unit)? = null, onEnd: ((String?) -> Unit)? = null) {
        if (context.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            throw SeraPlatformFailure("microphone_denied", "麦克风权限尚未开启。")
        if (recorder != null || worker != null) throw SeraPlatformFailure("recording_busy", "已有录音正在进行，请先完成或取消。")
        val minimum = AudioRecord.getMinBufferSize(16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minimum <= 0) throw SeraPlatformFailure("audio_unavailable", "设备不支持 16 kHz 单声道录音。")
        val audio = AudioRecord(MediaRecorder.AudioSource.MIC, 16000, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum * 2, 8192))
        if (audio.state != AudioRecord.STATE_INITIALIZED) { audio.release(); throw SeraPlatformFailure("audio_unavailable", "设备麦克风初始化失败，可能正在被其他应用占用。") }
        try { audio.startRecording() } catch (error: Exception) { audio.release(); throw SeraPlatformFailure("audio_unavailable", error.message ?: "麦克风无法开始录音。") }
        if (audio.recordingState != AudioRecord.RECORDSTATE_RECORDING) { audio.release(); throw SeraPlatformFailure("audio_unavailable", "系统未开始录音。") }
        captured = ByteArrayOutputStream(); streaming = onPcm != null; cancelled = false; failure = null; running = true; recorder = audio
        worker = Thread {
            val buffer = ByteArray(4096)
            val frame = ByteArray(3200)
            var used = 0
            try {
                // 60 seconds at 16000 Hz, 16 bits, mono = 1,920,000 bytes.
                val limit = 16000 * 2 * 60
                while (running && captured.size() < limit) {
                    val count = audio.read(buffer, 0, minOf(buffer.size, limit - captured.size()))
                    if (count > 0) {
                        captured.write(buffer, 0, count)
                        if (onPcm != null) {
                            var offset = 0
                            while (offset < count) {
                                val bytes = minOf(frame.size - used, count - offset)
                                buffer.copyInto(frame, used, offset, offset + bytes)
                                used += bytes; offset += bytes
                                if (used == frame.size) { onPcm(frame.copyOf()); used = 0 }
                            }
                        }
                    }
                    else if (running) { failure = "系统音频读取失败（$count）。"; break }
                }
            } catch (error: Exception) { if (!cancelled) failure = error.message ?: "录音被系统中断。" }
            finally {
                if (onPcm != null && used > 0 && !cancelled && failure == null) onPcm(frame.copyOf(used - used % 2))
                running = false; try { audio.stop() } catch (_: Exception) {}; audio.release(); recorder = null
                onEnd?.invoke(if (cancelled) null else failure)
            }
        }.apply { name = "SERA microphone"; start() }
    }
    private fun endCapture() {
        running = false
        try { recorder?.stop() } catch (_: Exception) {}
        worker?.join(3000)
        if (worker?.isAlive == true) throw SeraPlatformFailure("audio_stop_failed", "录音线程未及时停止，请返回重试。")
        worker = null
    }
    fun stop(): Map<String, Any> {
        if (worker == null && captured.size() == 0) throw SeraPlatformFailure("not_recording", "尚未开始录音。")
        endCapture()
        if (cancelled) throw SeraPlatformFailure("cancelled", "已取消录音。")
        failure?.let { throw SeraPlatformFailure("recording_failed", it) }
        val pcm = captured.toByteArray(); captured.reset()
        if (pcm.isEmpty()) throw SeraPlatformFailure("empty_audio", "麦克风没有产生可用音频，请重试。")
        val wav = ByteBuffer.allocate(44 + pcm.size).order(ByteOrder.LITTLE_ENDIAN)
        wav.put("RIFF".toByteArray()).putInt(36 + pcm.size).put("WAVEfmt ".toByteArray()).putInt(16).putShort(1).putShort(1)
            .putInt(16000).putInt(32000).putShort(2).putShort(16).put("data".toByteArray()).putInt(pcm.size).put(pcm)
        return mapOf("base64" to Base64.encodeToString(wav.array(), Base64.NO_WRAP), "mimeType" to "audio/wav",
            "fileName" to "sera-recording.wav", "durationMilliseconds" to pcm.size * 1000L / 32000L)
    }
    fun stopStream(cancel: Boolean) { if (!streaming) return; if (cancel) this.cancel() else { endCapture(); captured.reset(); streaming = false } }
    fun cancel() { streaming = false; cancelled = true; endCapture(); captured.reset(); failure = null }
}
