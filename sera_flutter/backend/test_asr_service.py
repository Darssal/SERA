import io
import json
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import wave
from ai_service import AiServiceError
from asr_service import parse_audio_upload, validate_audio, SiliconFlowTranscriber


def wav_data(seconds=1):
    out = io.BytesIO()
    with wave.open(out, 'wb') as wav:
        wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(8000)
        wav.writeframes(b'\0\0' * int(seconds * 8000))
    return out.getvalue()


class AsrTests(unittest.TestCase):
    def test_wav_duration_size_and_content_are_validated(self):
        self.assertEqual(validate_audio(wav_data(), 'recording.wav'), 1)
        for data in (b'not audio', wav_data(61), wav_data()[:-30]):
            with self.assertRaises(AiServiceError): validate_audio(data, 'recording.wav')

    def test_multipart_rejects_spoofed_content_and_accepts_wav(self):
        def upload(data):
            raw = b'--test\r\nContent-Disposition: form-data; name="file"; filename="voice.wav"\r\nContent-Type: audio/wav\r\n\r\n' + data + b'\r\n--test--\r\n'
            return parse_audio_upload('multipart/form-data; boundary=test', io.BytesIO(raw), len(raw))
        self.assertEqual(upload(wav_data())[1:], ('recording.wav', 'audio/wav'))
        with self.assertRaises(AiServiceError): upload(b'forged file')

    @patch.dict('os.environ', {'FFPROBE_PATH': 'unit-ffprobe'})
    @patch('asr_service.subprocess.run')
    def test_webm_real_metadata_and_packet_duration_limits(self, probe):
        def response(duration, media='audio'):
            return SimpleNamespace(returncode=0, stdout=json.dumps({'streams': [{'codec_type': media, 'codec_name': 'opus'}],
                'packets': [{'pts_time': '0', 'duration_time': str(duration)}]}).encode())
        probe.return_value = response(5)
        self.assertEqual(validate_audio(b'\x1aE\xdf\xa3test', 'recording.webm'), 5)
        for output in (response(70), response(5, 'video')):
            probe.return_value = output
            with self.assertRaises(AiServiceError): validate_audio(b'\x1aE\xdf\xa3test', 'recording.webm')

    @patch('asr_service.urlopen')
    def test_real_provider_contract_preserves_text_and_never_returns_key(self, provider):
        provider.return_value = io.BytesIO(json.dumps({'text': '准备课程答辩'}).encode())
        key = 'sk-unit-asr-not-real-secret'
        result = SiliconFlowTranscriber(key).transcribe(wav_data(), 'recording.wav', 'audio/wav')
        self.assertEqual(result['text'], '准备课程答辩')
        self.assertEqual(result['source'], 'siliconflow')
        self.assertNotIn(key, json.dumps(result))
        self.assertIn(b'FunAudioLLM/SenseVoiceSmall', provider.call_args.args[0].data)
        provider.reset_mock()
        with self.assertRaises(AiServiceError): SiliconFlowTranscriber(key).transcribe(wav_data(61), 'recording.wav', 'audio/wav')
        provider.assert_not_called()


if __name__ == '__main__': unittest.main()
