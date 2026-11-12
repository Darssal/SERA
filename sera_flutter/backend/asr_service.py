"""Bounded audio upload validation and authenticated server-side ASR."""
from email.parser import BytesParser
from email.policy import default
import io
import json
import math
import os
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import struct
import tempfile
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import wave

from ai_service import AiServiceError

MAX_AUDIO = 10 * 1024 * 1024


def parse_audio_upload(content_type, stream, length):
    if length < 1 or length > MAX_AUDIO + 16384:
        raise AiServiceError('音频上传不得超过 10 MiB。', 413, 'audio_too_large')
    if not content_type.lower().startswith('multipart/form-data;'):
        raise AiServiceError('音频上传需使用 multipart/form-data。', 400, 'invalid_audio')
    raw = stream.read(length)
    message = BytesParser(policy=default).parsebytes(('Content-Type: ' + content_type + '\r\nMIME-Version: 1.0\r\n\r\n').encode() + raw)
    if not message.is_multipart():
        raise AiServiceError('音频表单无效。', 400, 'invalid_audio')
    parts = list(message.iter_parts())
    files = [part for part in parts if part.get_param('name', header='content-disposition') == 'file']
    if len(parts) > 4 or len(files) != 1:
        raise AiServiceError('请只上传一份录音文件。', 400, 'invalid_audio')
    part = files[0]
    audio = part.get_payload(decode=True)
    if not audio or len(audio) > MAX_AUDIO:
        raise AiServiceError('录音为空或超过 10 MiB。', 413, 'audio_too_large')
    filename = Path((part.get_filename() or '').replace('\\', '/')).name
    mime = part.get_content_type()
    if (filename.lower().endswith('.wav') and mime in ('audio/wav', 'audio/x-wav', 'audio/wave') and audio[:4] == b'RIFF' and audio[8:12] == b'WAVE'):
        return audio, 'recording.wav', 'audio/wav'
    if filename.lower().endswith('.webm') and mime in ('audio/webm', 'video/webm') and audio[:4] == b'\x1aE\xdf\xa3':
        return audio, 'recording.webm', 'audio/webm'
    raise AiServiceError('仅支持内容与扩展名一致的 WAV / WebM 音频。', 400, 'invalid_audio')


def validate_audio(audio, filename):
    if not audio or len(audio) > MAX_AUDIO:
        raise AiServiceError('录音为空或超过 10 MiB。', 413, 'audio_too_large')
    if filename.endswith('.wav'):
        try:
            if len(audio) < 44 or audio[:4] != b'RIFF' or audio[8:12] != b'WAVE' or struct.unpack('<I', audio[4:8])[0] + 8 != len(audio):
                raise ValueError()
            offset, data_chunks = 12, 0
            while offset < len(audio):
                if offset + 8 > len(audio): raise ValueError()
                size = struct.unpack('<I', audio[offset + 4:offset + 8])[0]
                if audio[offset:offset + 4] == b'data': data_chunks += 1
                offset += 8 + size + (size % 2)
                if offset > len(audio): raise ValueError()
            if data_chunks != 1: raise ValueError()
            with wave.open(io.BytesIO(audio)) as wav:
                rate, channels, width, frames = wav.getframerate(), wav.getnchannels(), wav.getsampwidth(), wav.getnframes()
                if not 8000 <= rate <= 96000 or channels not in (1, 2) or width not in (1, 2, 3, 4):
                    raise ValueError()
                duration = frames / rate
                if len(wav.readframes(frames)) != frames * channels * width:
                    raise ValueError()
        except (wave.Error, ValueError, EOFError):
            raise AiServiceError('WAV 音频格式或数据无效。', 400, 'invalid_audio') from None
    elif filename.endswith('.webm'):
        probe = os.environ.get('FFPROBE_PATH') or shutil.which('ffprobe')
        if not probe:
            raise AiServiceError('服务端缺少 WebM 校验器，请配置 FFPROBE_PATH 或改录 WAV。', 503, 'audio_validator_unavailable')
        with tempfile.TemporaryDirectory(prefix='sera-audio-') as directory:
            path = Path(directory) / 'recording.webm'
            path.write_bytes(audio)
            try:
                result = subprocess.run([probe, '-v', 'error', '-show_entries',
                    'stream=codec_type,codec_name:format=duration:packet=pts_time,duration_time',
                    '-show_streams', '-show_format', '-show_packets', '-of', 'json', str(path)],
                    capture_output=True, timeout=12, check=False)
                if result.returncode or len(result.stdout) > 32 * 1024 * 1024:
                    raise ValueError()
                data = json.loads(result.stdout)
                streams = data.get('streams', [])
                if len(streams) != 1 or streams[0].get('codec_type') != 'audio' or streams[0].get('codec_name') not in ('opus', 'vorbis'):
                    raise ValueError()
                values = [float(p['pts_time']) + float(p.get('duration_time', 0)) for p in data.get('packets', []) if 'pts_time' in p]
                if data.get('format', {}).get('duration') is not None:
                    values.append(float(data['format']['duration']))
                duration = max(values) if values else 0
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
                raise AiServiceError('WebM 需为有效的单音轨 Opus/Vorbis 录音。', 400, 'invalid_audio') from None
    else:
        raise AiServiceError('不支持的音频格式。', 400, 'invalid_audio')
    if not math.isfinite(duration) or not 0.1 <= duration <= 60.1:
        raise AiServiceError('录音时长需在 0.1 至 60 秒之间。', 400, 'audio_duration_invalid')
    return duration


class SiliconFlowTranscriber:
    def __init__(self, api_key='', model='FunAudioLLM/SenseVoiceSmall'):
        self._api_key, self.model = api_key, model

    def transcribe(self, audio, filename, content_type):
        duration = validate_audio(audio, filename)
        if not self._api_key:
            raise AiServiceError('语音服务密钥尚未配置。', 503, 'asr_not_configured')
        boundary = 'sera-' + secrets.token_hex(16)
        body = (f'--{boundary}\r\nContent-Disposition: form-data; name="model"\r\n\r\n{self.model}\r\n'
                f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{filename}"\r\nContent-Type: {content_type}\r\n\r\n').encode() + audio + f'\r\n--{boundary}--\r\n'.encode()
        request = Request('https://api.siliconflow.cn/v1/audio/transcriptions', data=body, method='POST',
            headers={'Authorization': 'Bearer ' + self._api_key, 'Content-Type': 'multipart/form-data; boundary=' + boundary})
        try:
            with urlopen(request, timeout=45) as response:
                raw = response.read(256 * 1024 + 1)
            if len(raw) > 256 * 1024: raise ValueError()
            text = json.loads(raw)['text']
            if not isinstance(text, str) or not text.strip() or len(text) > 20000: raise ValueError()
            return {'text': text.strip(), 'source': 'siliconflow', 'model': self.model, 'durationSeconds': round(duration, 3)}
        except HTTPError as exc:
            raise AiServiceError('语音服务限流，请稍后重试。' if exc.code == 429 else '语音服务拒绝请求，请检查模型、密钥和账户额度。',
                                 429 if exc.code == 429 else 502, 'asr_provider_error') from None
        except (socket.timeout, TimeoutError):
            raise AiServiceError('语音识别超时，请重试。', 504, 'asr_timeout') from None
        except URLError:
            raise AiServiceError('无法连接语音识别服务。', 502, 'asr_connection_error') from None
        except (ValueError, KeyError, TypeError):
            raise AiServiceError('语音服务没有返回有效文字，请重录。', 502, 'invalid_asr_output') from None
