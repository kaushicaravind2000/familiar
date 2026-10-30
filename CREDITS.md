**Familiar** runs these models and libraries on your Mac. The models aren't bundled with the app: it downloads each one from Hugging Face on first use, at a pinned revision, checked against a fixed SHA-256.

**Models**

**EmbeddingGemma 2** by Google DeepMind, for search. Apache 2.0. GGUF by ggml-org. Gemma is a trademark of Google LLC. https://huggingface.co/google/embeddinggemma-2

**Qwen3.5-4B** by the Qwen team (Alibaba Cloud), for Ask. Apache 2.0. GGUF by Unsloth. https://huggingface.co/Qwen/Qwen3.5-4B

**Parakeet Unified 0.6B (English)** by NVIDIA, for speech to text. Licensed by NVIDIA Corporation under the NVIDIA Open Model License (https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-license/). Core ML conversion by Fluid Inference. https://huggingface.co/nvidia/parakeet-unified-en-0.6b

**LocalVQE v1.3** by LocalAI, for removing the call's sound from your microphone in meetings. Apache 2.0. Core ML conversion by Fluid Inference. https://huggingface.co/LocalAI-io/LocalVQE

**Speaker separation** (who spoke when in a meeting): the pyannote speaker-diarization-community-1 pipeline by pyannote, with WeSpeaker speaker embeddings and PLDA parameters from Brno University of Technology (BUT Speech@FIT), each under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/). Familiar uses Fluid Inference's modified Core ML conversions; their attribution notice and the original citations are at https://huggingface.co/FluidInference/speaker-diarization-coreml

**Libraries**

**llama.cpp and ggml** by ggml-org and contributors, which run the search and answer models. MIT. https://github.com/ggml-org/llama.cpp

**FluidAudio** by Fluid Inference, which runs the speech models on the Neural Engine. Apache 2.0. https://github.com/FluidInference/FluidAudio

**SQLite**, the index. Public domain. https://sqlite.org

**DigUp** by Abdur Rahim, the open-source file search for Mac, Windows and Linux whose design inspired Familiar's: describing a file to find it with EmbeddingGemma 2. MIT. https://github.com/ARahim3/DigUp

Text in pictures and scans is read with Apple's Vision framework, part of macOS.

The licence texts of the programs built into the app are in THIRD-PARTY-NOTICES.md.
