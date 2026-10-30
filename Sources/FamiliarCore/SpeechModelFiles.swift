import Foundation

/// The speech models, pinned like EmbeddingGemma and Qwen: an exact Hugging Face revision and a SHA-256 for every file,
/// downloaded by the app itself (FluidAudio would otherwise fetch Parakeet from "main", unchecked). Generated from the
/// copies FluidAudio 0.17.7 downloaded on 2026-10-23, each checked against the repository at these revisions.
/// Folders are where FluidAudio looks for them (under Models/Speech), so the helper only compiles them.
public enum SpeechModelFiles {
    /// Parakeet TDT 0.6B v3, Core ML (FluidInference; NVIDIA's model, CC BY 4.0): 23 files, 483 MB.
    public static let parakeet: [EmbeddingModelFiles.File] = {
        let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml", revision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
        return [
        EmbeddingModelFiles.File(name: "Decoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Decoder.mlmodelc/coremldata.bin", bytes: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Decoder.mlmodelc/metadata.json", bytes: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Decoder.mlmodelc/model.mil", bytes: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Decoder.mlmodelc/weights/weight.bin", bytes: 23604992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Encoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Encoder.mlmodelc/coremldata.bin", bytes: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Encoder.mlmodelc/metadata.json", bytes: 2921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Encoder.mlmodelc/model.mil", bytes: 959769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Encoder.mlmodelc/weights/weight.bin", bytes: 445187200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "JointDecisionv3.mlmodelc/coremldata.bin", bytes: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "JointDecisionv3.mlmodelc/metadata.json", bytes: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "JointDecisionv3.mlmodelc/model.mil", bytes: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "JointDecisionv3.mlmodelc/weights/weight.bin", bytes: 12642764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Preprocessor.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Preprocessor.mlmodelc/coremldata.bin", bytes: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Preprocessor.mlmodelc/metadata.json", bytes: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Preprocessor.mlmodelc/model.mil", bytes: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "Preprocessor.mlmodelc/weights/weight.bin", bytes: 491072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "config.json", bytes: 475, sha256: "97f19ecccd0fdc730d76fb918090fa8bc64bce8ea4ad43715d5e9c2c7350db66",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "parakeet_v3_vocab.json", bytes: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        EmbeddingModelFiles.File(name: "parakeet_vocab.json", bytes: 151122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735",
                        repository: repo, revision: revision, folder: "Speech/parakeet-tdt-0.6b-v3"),
        ]
    }()

    /// Parakeet Unified 0.6B, English, Core ML (FluidInference's conversion, which it labels CC BY 4.0, of NVIDIA's model
    /// under the NVIDIA Open Model License; CREDITS.md): the streaming encoder for
    /// 1.12 s latency (left 70, chunk 7, look-ahead 7 frames, int8), the full-attention encoder for whole clips (int8),
    /// their shared decoder and joint, and the vocabulary: 17 files, 1.2 GB. Writes punctuation and capitals. The stream
    /// shows words as they're said; the whole clip, which hears every word with what comes after it, writes the text
    /// that's kept: a dictation once the key is let go, a meeting once it ends, and recordings in folders.
    public static let unified: [EmbeddingModelFiles.File] = {
        let repo = "FluidInference/parakeet-unified-en-0.6b-coreml", revision = "d32e972dd4315f1dc3f6be28fb2aab0ab3e80358"
        return [
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "2e1831ca50902be65664ab7dd1182f0d096eaef387e424b135f8cf896ffcec2e",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc/coremldata.bin", bytes: 513, sha256: "5f174a7cf6b1a9dd77fb479194f8a286e99d4375b67a86ffc66a42fb36e4d0dc",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc/model.mil", bytes: 935329, sha256: "ce508730f3ea72cc8459ac491a8afd3477cee7f88b13d2eb5628ea60eef94f22",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_streaming_70_7_7_int8.mlmodelc/weights/weight.bin", bytes: 589979840, sha256: "f145c8da6226eb2ad1c312d1a44c7757c97b0b941c73725b36b28ff17d12285b",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_int8.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "57e116a9d5765e39c0cdf754137ab744ddae34d9c6d68a5fdcad6600ae3a7b6b",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_int8.mlmodelc/coremldata.bin", bytes: 492, sha256: "54f533d30343d5e62b324a0691e4c262a6768b07b6e88e7aa14c617a2baba8a3",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_int8.mlmodelc/model.mil", bytes: 1110902, sha256: "c1c5d71c6cbf4d35bba08458746bde3640da7b1b444e1229a269393a58222c10",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_encoder_int8.mlmodelc/weights/weight.bin", bytes: 595051904, sha256: "f984b81590a4deae041ae20fbab8981c2d2a5b528b2ac81fae81c432633535c6",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_decoder.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "9ae70f6559989f88b856b326e59315798f9f0d08207a19fcc2dd3287a30088a5",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_decoder.mlmodelc/coremldata.bin", bytes: 560, sha256: "ce99c4488840fc463d59f8d4d6d2a9e8ceae8138ead51e3c265dde4d2ba4a0e9",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_decoder.mlmodelc/model.mil", bytes: 13102, sha256: "6e60965b89c93943aa2be2d991c2461108145851fde05e1d048223a32d4cb20d",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_decoder.mlmodelc/weights/weight.bin", bytes: 14429952, sha256: "96f990461a5986d5e7309ad1a0f36084fbf0f4b28aec35948f8b8d0dcbf8599e",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_joint_decision_single_step.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "163877ad14af97ec4107cd854fd1c6d336ee5d40ad25a657cc764fb763f452f5",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_joint_decision_single_step.mlmodelc/coremldata.bin", bytes: 556, sha256: "68a081570a48b52ec9379e153bd56748a5408a50be16767601563f231eaeff03",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_joint_decision_single_step.mlmodelc/model.mil", bytes: 9611, sha256: "03c21096090bcd0b71c896c5ae0eb815db31a91c6676f572a7868eee4299abe3",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin", bytes: 3446978, sha256: "06831afa6d1beb0c0b10350ebf7886bc37638e951d14e738d7e06fbd2a05012f",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),
        EmbeddingModelFiles.File(name: "vocab.json", bytes: 15088, sha256: "e1a7bff4f5df133c0f4ad47b8e43c96f6bf1865d99126a4c4725ef51d0108bec",
                        repository: repo, revision: revision, folder: "Speech/parakeet-unified-en"),

        ]
    }()

    /// LocalVQE v1.3 echo cancellation (Apache 2.0; FluidInference's Core ML conversion), 256 ms per call: 4 files,
    /// 19 MB. Cleans the call's sound out of the microphone in a meeting without headphones.
    public static let echo: [EmbeddingModelFiles.File] = {
        let repo = "FluidInference/localvqe-coreml", revision = "4205430781c240397073d6f7bf676fb4c732fc12"
        return [
        EmbeddingModelFiles.File(name: "localvqe-v1.3-4.8M-256ms.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "a0e97d957f54c9a144993bfbb9d3d8320def9de35a77844e20fbf0703fa461c6",
                        repository: repo, revision: revision, folder: "Speech/localvqe"),
        EmbeddingModelFiles.File(name: "localvqe-v1.3-4.8M-256ms.mlmodelc/coremldata.bin", bytes: 3531, sha256: "9ac719cbfbc018ce1f1168062ee1629b77bd86f4881567bca8668591817f402f",
                        repository: repo, revision: revision, folder: "Speech/localvqe"),
        EmbeddingModelFiles.File(name: "localvqe-v1.3-4.8M-256ms.mlmodelc/model.mil", bytes: 349829, sha256: "11da4803a13bcc357550904fcbfeb4a169b0c4b38e529787aeed8a9b233c528c",
                        repository: repo, revision: revision, folder: "Speech/localvqe"),
        EmbeddingModelFiles.File(name: "localvqe-v1.3-4.8M-256ms.mlmodelc/weights/weight.bin", bytes: 19281728, sha256: "fc5f290cbfb497718d9d9568ee965c352bfe4663bab49b30a10e91f8fcfff826",
                        repository: repo, revision: revision, folder: "Speech/localvqe"),

        ]
    }()

    /// The speaker-separation models (FluidInference's Core ML conversion): 24 files, 21 MB.
    /// FluidAudio checks a revision marker in this folder; `markRevision()` writes it.
    public static let diarizer: [EmbeddingModelFiles.File] = {
        let repo = "FluidInference/speaker-diarization-coreml", revision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
        return [
        EmbeddingModelFiles.File(name: "Embedding.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Embedding.mlmodelc/coremldata.bin", bytes: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Embedding.mlmodelc/metadata.json", bytes: 2818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Embedding.mlmodelc/model.mil", bytes: 78432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Embedding.mlmodelc/weights/weight.bin", bytes: 13412288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "FBank.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "FBank.mlmodelc/coremldata.bin", bytes: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "FBank.mlmodelc/metadata.json", bytes: 3409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "FBank.mlmodelc/model.mil", bytes: 15667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "FBank.mlmodelc/weights/weight.bin", bytes: 1776896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "PldaRho.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "PldaRho.mlmodelc/coremldata.bin", bytes: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "PldaRho.mlmodelc/metadata.json", bytes: 2749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "PldaRho.mlmodelc/model.mil", bytes: 7613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "PldaRho.mlmodelc/weights/weight.bin", bytes: 200192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Segmentation.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Segmentation.mlmodelc/coremldata.bin", bytes: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Segmentation.mlmodelc/metadata.json", bytes: 3410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Segmentation.mlmodelc/model.mil", bytes: 43063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "Segmentation.mlmodelc/weights/weight.bin", bytes: 5959360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "config.json", bytes: 2, sha256: "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "plda-parameters.json", bytes: 89416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "provenance.json", bytes: 10048, sha256: "0353430db062715c411ba32e66cb435b9caee2662bccdb298f9e5d1bae760872",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        EmbeddingModelFiles.File(name: "xvector-transform.json", bytes: 177499, sha256: "f7cd5cc16e63e2d89db052a23018ecfc47a311998ed1e9e39838fbac65048688",
                        repository: repo, revision: revision, folder: "Speech/diarizer/speaker-diarization"),
        ]
    }()

    public static let diarizerRevision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
    /// What the app downloads: English speech (Unified), echo cancellation and speaker separation. `parakeet` (TDT v3, 25 European
    /// languages) is no longer downloaded; a copy from before is removed once Unified is ready.
    public static var all: [EmbeddingModelFiles.File] { unified + echo + diarizer }
    public static var totalBytes: Int64 { all.reduce(0) { $0 + $1.bytes } }

    /// FluidAudio reuses a pinned download only when this marker names its revision.
    static func markRevision() {
        let marker = AppPaths.models.appendingPathComponent("Speech/diarizer/speaker-diarization/.fluidaudio-revision")
        try? diarizerRevision.write(to: marker, atomically: true, encoding: .utf8)
    }

    /// Files already on disk from before pinning (fetched by FluidAudio itself) are checked once against their SHA-256;
    /// one that doesn't match is removed, so the download replaces it.
    static func removeUnverified() {
        for file in all where file.isInstalled {
            if (try? EmbeddingModelFiles.sha256(of: file.installed)) != file.sha256 { try? FileManager.default.removeItem(at: file.installed) }
        }
    }
}
