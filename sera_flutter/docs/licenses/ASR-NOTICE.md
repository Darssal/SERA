# ASR 权重与运行库归属说明

核对日期：2026-10-31。此说明由SERA交付方整理，不冒充上游自带NOTICE。模型权重与推理运行库分别核对许可。

## 模型权重

资源名称：sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16。官方sherpa文档明确记录该ONNX模型转换自Hugging Face的csukuangfj/k2fsa-zipformer-bilingual-zh-en-t；来源模型卡明确标注Apache-2.0，而非根据运行库许可推断权重许可。核对的模型仓库commit为e2382758de9a0219b4efe682b95af30b399db3b8。模型卡同时保留其原始来源pfluo/k2fsa-zipformer-chinese-english-mixed的署名链接。

- [官方转换关系与下载说明](https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/zipformer-transducer-models.html#sherpa-onnx-streaming-zipformer-small-bilingual-zh-en-2023-02-16-bilingual-chinese-english)
- [固定版本来源模型卡及许可元数据](https://huggingface.co/csukuangfj/k2fsa-zipformer-bilingual-zh-en-t/blob/e2382758de9a0219b4efe682b95af30b399db3b8/README.md)
- [官方ONNX发布资产](https://github.com/k2-fsa/sherpa-onnx/releases/tag/asr-models)

权重包随附zipformer-model-LICENSE-Apache-2.0.txt及asr-provenance.json，保留来源、许可证与哈希信息。SERA未训练、微调、重新量化或编辑权重，仅从官方归档选择原始int8 encoder、float decoder、int8 joiner及tokens.txt并增加完整性manifest；原字节保持不变。由上游完成的训练/ONNX转换/量化归属于来源作者与贡献者，不宣称由SERA开发。

检查的官方归档未附模型独立LICENSE/NOTICE文件；许可依据是上述来源模型的明确声明及官方转换关系。交付包不含来源授权不明确的test_wavs样本，也不含原始训练数据。模型训练数据并未交付，模型许可不代表授权分发未提供的训练集。上游未列明的具体权利人名称与训练数据来源不由SERA自行补造。

## 推理运行库

sherpa-onnx 2.0.1由k2-fsa项目及贡献者维护，运行库代码采用Apache-2.0。附带sherpa-onnx-runtime-2.0.1-LICENSE.txt，内容取自已安装官方2.0.1 wheel的.dist-info/LICENSE，与固定tag一致。

- [运行库固定版本许可](https://github.com/k2-fsa/sherpa-onnx/blob/v2.0.1/LICENSE)
- [运行库源码](https://github.com/k2-fsa/sherpa-onnx)

本工程通过requirements安装运行库；独立模型ZIP只包含模型字节和归属材料，不把运行库二进制、ONNX Runtime或其第三方依赖一起重新分发。若另行分发运行库二进制，需同时保留该二进制附带的第三方许可证与通知，不能仅使用本说明替代整个依赖链的许可材料。
