# 已校验的本地流式 ASR

模型为 k2-fsa/sherpa-onnx 的 `sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16`，CPU、2线程、greedy_search，输入为16kHz单声道PCM16。独立本地推理与用户显式触发的云端备用识别分别实现。

## 官方运行文件与完整性

采用官方量化组合 **int8 encoder + float decoder + int8 joiner**。原先将 decoder 也选成 int8 会导致严重漏字，已通过同一音频单变量对照确认并修复。下载、加载和打包三处使用同一份固定文件名及 SHA256；缺少正确 decoder 或字节损坏时直接拒绝，不回退。

| 文件 | 字节 | SHA256 |
| --- | ---: | --- |
| encoder-epoch-99-avg-1.int8.onnx | 42,980,793 | `db6f51551762e40e549166fe041ea3e45464370b595e9ad23f06478ec3794fbb` |
| decoder-epoch-99-avg-1.onnx | 13,877,276 | `89be509a83175261695bdef5fd1c7b9ab1129a663d1284e7ba9f8507b21e0906` |
| joiner-epoch-99-avg-1.int8.onnx | 3,228,485 | `bdda356d6f9b8c2d7cee9ee0e26075fa537490f7fd06520be408d287073667b9` |
| tokens.txt | 56,317 | `a8e0e4ec53810e433789b54a5c0134a7eaa2ffca595a6334d54c00da858841d3` |

官方归档458,187,351字节，固定SHA256 `2b7c63322b32e5e0f2526043a1103366119ca58dd615cd7105a37c01db9553d7`。下载脚本拒绝目录穿越和符号链接，生成带 configuration/runtimeFiles 的 manifest。旧 int8 decoder 可以保留在已有本机缓存中，但不参与加载、清单或独立资源包。

```powershell
backend/.venv/Scripts/python.exe backend/download_asr_model.py
backend/.venv/Scripts/python.exe backend/local_asr.py --db backend/sera.sqlite3
backend/.venv/Scripts/python.exe scripts/package-models.py
```

[官方量化组合与使用说明](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html#sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16-bilingual-chinese-english)及[官方发布资产](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)。权重来源模型明确声明 Apache-2.0；运行库2.0.1另有独立许可，固定来源和两份LICENSE见[归属说明](licenses/ASR-NOTICE.md)。资源包只含上述运行文件、清单及许可，不含测试音频、训练数据、未使用的其他权重或客户端模型。

## 固定样本的计算与实时节拍

修复后的官方 `test_wavs/0.wav`，10.053125秒，SHA256 `7d93384ca14702cc584a7a33fe2fed92e89e708549161cb12ea38c916882103b`，本机模型加载 0.434秒，批量加速喂帧解码 0.230秒，计算RTF 0.02288，14次 partial。首个 partial 需要1.1秒音频，其加速计算时间不代表真实录音等待。原样输出：`昨天是 MONDAY TODAY IS THEY AFTER TOMORROW是星期三`。

另以真实100ms节拍，经独立临时数据库和回环TCP WebSocket完成5次单路及3轮两账号并发（6条流）；第一帧在首100ms音频形成后发送。

| P95，线性插值 | 单路 n=5 | 两账号并发 n=6 |
| --- | ---: | ---: |
| 音频起点至首个 partial | 1.1121秒 | 1.1213秒 |
| finish 至 final | 19.98毫秒 | 36.38毫秒 |
| 服务端解码等待RTF | 0.03010 | 0.04602 |
| 含节拍等待的总壁钟RTF | 1.00206 | 1.00366 |

服务端指标包含调度、推理与锁等待；总壁钟RTF接近1是按真实语速喂帧的结果。当前配置及旧配置结果分别保存在[计算基准](qa/local-asr-benchmark.json)和[实时节拍记录](qa/asr-realtime-latency.json)，旧记录位于 previousConfiguration。不能用单个官方样本推导手机端到端延迟或识别准确率。

```powershell
backend/.venv/Scripts/python.exe backend/local_asr.py --benchmark backend/models/sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16/test_wavs/0.wav
backend/.venv/Scripts/python.exe backend/benchmark_realtime_asr.py
```

## 固定合成语料与识别质量

使用已有 Microsoft Huihui Desktop zh-CN 合成6条固定语料，覆盖中文日程、相对日期、数字日期和 Flutter/Android/Web/API/Dart/HTTP。修复前后使用相同WAV及哈希、PCM归一、100ms分帧、结束流程与CER规则，没有重写识别结果或重合成音频。

修正后合计151个参考字符、39次编辑，严格加权CER **25.83%**；旧错误组合为78.81%。中文日程、相对日期时长、取消计划三条的CER为0；数字日期输出为中文数字，按不转换数字的严格规则仍计8次编辑；两条中英混合分别19/12次编辑。原文、原始输出、前后结果及控制条件在[固定语料记录](qa/asr-fixed-corpus.json)，当前结果位置为 `correction.after`。

**这是合成固定语料，非真人准确率。** 不外推口音、噪声、自然停顿、手机麦克风或通用中英混合能力。中英词仍可能漏识或错识，用户需在校对页确认日期与文字后再规划；云端备用识别由用户明确触发。语音链路可运行不等于已经取得高识别准确率。

## 协议、平台证据与隐私

鉴权API申请2分钟单次HMAC票据；WebSocket先发start，再发每100ms约3200字节的PCM。partial/final是累计整段文字，finish补尾部0.5秒静音并 input_finished 后完成真实解码，cancel释放流。每账号1路、全局2路、音频60秒；票据校验会话，过期/重放被拒绝，登出使后续帧失效。服务不保存原始录音，关闭WS访问日志避免泄露票据。

后端53项回归包括2项真实模型WS/票据/取消/并发测试及4项新增模型选型/完整性测试。MuMu1实际AudioRecord产生PCM/WAV，浏览器固定样本通过真实AudioWorklet、WS和编辑稿，分别见[设备记录](qa/mumu1-platform.json)与[浏览器记录](qa/web-ai-voice.json)；这些平台记录在模型修复前完成，界面/传输代码未变。修复后真实WS解码和延迟已重测，不能把固定样本模拟麦克风当作真人测试或完整Android语音质量验收。
