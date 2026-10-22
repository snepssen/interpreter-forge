import Foundation
import ModelStore

/// A translation model the app can download, pinned to a revision.
///
/// Not everyone needs the same one: a phone with 8 GB runs a 4B model with
/// little to spare, and a smaller one runs smoother between steps. Measured
/// with scripts/compare-models.py on 26 lines across ten languages and the
/// complete-thought judge's 17 cases, and with tcrun on 8 minutes of fast
/// Polish and Hungarian conversation: median lag 4.4 s with Qwen, 6.7 s with
/// TranslateGemma, which has no judge and so cuts later.
public struct TranslationModel: Identifiable, Hashable, Sendable {
    public enum Style: Sendable {
        /// A general instruction model, given our interpreter instructions; it
        /// can also be the judge of when a thought is complete.
        case instructions
        /// TranslateGemma: its own template, told the source language, no
        /// instructions; not asked anything but translations.
        case translateGemma
        /// EuroLLM: its own translation format from its training, told the
        /// source language, one piece at a time. Given our interpreter
        /// instructions it echoed them, answered questions instead of
        /// translating them and remarked on the sentence; in its own format
        /// it translates. Not asked anything but translations: it judged 9
        /// of 17 complete thoughts.
        case euroLLM
    }

    public let id: String  // folder name, and what is remembered as the choice
    public let name: String
    /// A few words for a settings row.
    public let tagline: String
    public let summary: String
    public let repo: String
    public let revision: String
    public let style: Style
    /// Peak memory while translating, measured on a Mac; what a phone must spare.
    public let memoryGB: Double
    public let files: [ModelFile]

    public var download: Int64 { files.reduce(0) { $0 + $1.size } }
    public var judges: Bool { style == .instructions }

    /// Whether this device has the memory for it alongside speech recognition:
    /// TranslateGemma's 2.6 GB runs on an 8 GB iPhone 17; Gemma 4 E4B's 4.7 GB
    /// wants 12. A Mac has room for any of them.
    public var fits: Bool {
        #if os(macOS)
        true
        #else
        Double(ProcessInfo.processInfo.physicalMemory) / 1e9 >= memoryGB * 2.3
        #endif
    }
}

extension TranslationModel: StoredModel {}

public enum ModelCatalog {
    public static let translation: [TranslationModel] = [
        TranslationModel(
            id: "translategemma-4b-it-4bit", name: "TranslateGemma 4B", tagline: "Best translations",
            summary: "Google's translation model: the most accurate, natural English, 55 languages. It can't judge when a thought is complete, so in quick conversation it speaks a second or two later than Qwen.",
            repo: "mlx-community/translategemma-4b-it-4bit", revision: "5788ec08c047f3f2e17808101b8d9566ac930d58",
            style: .translateGemma, memoryGB: 2.6,
            files: [.init(name: "added_tokens.json", size: 35), .init(name: "chat_template.jinja", size: 16982),
                    .init(name: "config.json", size: 2815), .init(name: "generation_config.json", size: 128),
                    .init(name: "model.safetensors.index.json", size: 79768), .init(name: "special_tokens_map.json", size: 662),
                    .init(name: "tokenizer.json", size: 33_384_568), .init(name: "tokenizer.model", size: 4_689_074),
                    .init(name: "tokenizer_config.json", size: 1_155_413), .init(name: "model.safetensors", size: 2_183_295_977)]),
        TranslationModel(
            id: "qwen3-4b-instruct-2507-4bit", name: "Qwen3 4B", tagline: "Speaks sooner",
            summary: "The quickest in conversation: it also judges when a thought is complete, so it speaks sooner. Less natural English, and the odd wrong word.",
            repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b",
            style: .instructions, memoryGB: 2.8,
            files: [.init(name: "added_tokens.json", size: 707), .init(name: "chat_template.jinja", size: 4040),
                    .init(name: "config.json", size: 938), .init(name: "generation_config.json", size: 238),
                    .init(name: "merges.txt", size: 1_671_853), .init(name: "model.safetensors.index.json", size: 63964),
                    .init(name: "special_tokens_map.json", size: 613), .init(name: "tokenizer.json", size: 11_422_654),
                    .init(name: "tokenizer_config.json", size: 5440), .init(name: "vocab.json", size: 2_776_833),
                    .init(name: "model.safetensors", size: 2_263_022_417)]),
    ]

    // Gemma 4 E4B translated nearly as well as TranslateGemma (one meaning
    // error in 26, natural English, times as digits) but needs 4.7 GB: a 12 GB
    // iPhone or a Mac. E2B is the fastest (0.6 s a line) and the roughest (five
    // errors). Both judge less well than Qwen (13 and 12 of 17).
    // EuroLLM-1.7B-Instruct (utter-project, Apache-2.0): trained for the 24 EU
    // languages and instruction-tuned for translation, 0.93 GB, peak 1.1-1.4 GB
    // on a Mac. The only one that fits a 4 GB iPhone (13, 13 mini). Measured
    // 2026-10-15 in its own format: about 4 meaning errors in 21 lines into
    // English where TranslateGemma made 1, and into Hungarian and Polish about
    // two in three lines kept their meaning. The gist, for a phone that can
    // run nothing bigger. jevoma4362's MLX conversion, pinned: dequantised,
    // it is exactly as close to the official weights as our own conversion
    // with mlx-lm 0.32 (median error ratio 1.0000; the bytes differ only in
    // values on a rounding boundary).
    static let euroLLM = TranslationModel(
        id: "eurollm-1.7b-instruct-4bit", name: "EuroLLM 1.7B", tagline: "For 4 GB iPhones",
        summary: "A small European model for phones with 4 GB, like the iPhone 13: rougher translations, the gist rather than every word, in the 24 EU languages. It can't judge when a thought is complete or summarise.",
        repo: "jevoma4362/EuroLLM-1.7B-Instruct-mlx-4Bit", revision: "6564fac274047a98b97c54287607626553f5647f",
        style: .euroLLM, memoryGB: 1.4,
        files: [.init(name: "chat_template.jinja", size: 424), .init(name: "config.json", size: 917),
                .init(name: "generation_config.json", size: 132), .init(name: "model.safetensors.index.json", size: 39380),
                .init(name: "tokenizer.json", size: 15_783_363), .init(name: "tokenizer_config.json", size: 416),
                .init(name: "model.safetensors", size: 932_185_251)])

    static let gemma4: [TranslationModel] = [
        TranslationModel(
            id: "gemma-4-e4b-it-4bit", name: "Gemma 4 E4B", tagline: "Near-best, speaks sooner",
            summary: "Nearly TranslateGemma's quality and also judges when a thought is complete, but needs a Mac or an iPhone with 12 GB.",
            repo: "mlx-community/gemma-4-e4b-it-4bit", revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
            style: .instructions, memoryGB: 4.7,
            files: [.init(name: "chat_template.jinja", size: 17336), .init(name: "config.json", size: 6628),
                    .init(name: "generation_config.json", size: 208), .init(name: "model.safetensors.index.json", size: 240_961),
                    .init(name: "processor_config.json", size: 1316), .init(name: "tokenizer.json", size: 32_169_626),
                    .init(name: "tokenizer_config.json", size: 2740), .init(name: "model.safetensors", size: 5_146_800_534)]),
        TranslationModel(
            id: "gemma-4-e2b-it-4bit", name: "Gemma 4 E2B", tagline: "Fastest, roughest",
            summary: "The fastest, for a smooth run on a busy phone; rougher translations, more often wrong on details.",
            repo: "mlx-community/gemma-4-e2b-it-4bit", revision: "238767527555cb75a05732a84dff5d6ba0dd6809",
            style: .instructions, memoryGB: 3.0,
            files: [.init(name: "chat_template.jinja", size: 17336), .init(name: "config.json", size: 6395),
                    .init(name: "generation_config.json", size: 208), .init(name: "model.safetensors.index.json", size: 218_323),
                    .init(name: "processor_config.json", size: 1316), .init(name: "tokenizer.json", size: 32_169_626),
                    .init(name: "tokenizer_config.json", size: 2740), .init(name: "model.safetensors", size: 3_550_670_554)]),
    ]

    public static var all: [TranslationModel] { translation + gemma4 + [euroLLM] }

    /// What this device is offered. TranslateGemma's quality is the standard
    /// and the only way from it is up (owner's rule, 2026-10-15): EuroLLM is
    /// offered only where none of the others fits, a 4 GB iPhone, and is then
    /// the one recommended. Elsewhere it appears only once downloaded, so it
    /// can be deleted.
    public static var offered: [TranslationModel] {
        let standard = translation + gemma4
        if !standard.contains(where: \.fits) { return [euroLLM] }
        return standard + (Resources.models.isDownloaded(euroLLM) ? [euroLLM] : [])
    }

    public static var recommended: TranslationModel { translation[0].fits ? translation[0] : offered[0] }

    public static func model(_ id: String?) -> TranslationModel? { all.first { $0.id == id } }
}
