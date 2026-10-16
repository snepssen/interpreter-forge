package com.snepssen.translating

/**
 * What each translator is asked, in its own format, exactly as its official
 * chat template renders it (held to prompts.json, rendered by the models' own
 * tokenizers in Python). The Apple app asks the same questions.
 */
object Prompts {
    /** TranslateGemma's own names for the languages the app can hear. */
    val names = mapOf(
        "bg" to "Bulgarian", "cs" to "Czech", "da" to "Danish", "de" to "German", "el" to "Greek", "en" to "English",
        "es" to "Spanish", "et" to "Estonian", "fi" to "Finnish", "fr" to "French", "hr" to "Croatian", "hu" to "Hungarian",
        "it" to "Italian", "lt" to "Lithuanian", "lv" to "Latvian", "mt" to "Maltese", "nl" to "Dutch", "pl" to "Polish",
        "pt" to "Portuguese", "ro" to "Romanian", "ru" to "Russian", "sk" to "Slovak", "sl" to "Slovenian", "sv" to "Swedish",
        "uk" to "Ukrainian", "no" to "Norwegian", "ca" to "Catalan", "tr" to "Turkish",
    )

    fun name(code: String) = names[code] ?: code

    /** An earlier piece and its translation, carried as context. */
    data class Piece(val source: String, val text: String, val translation: String)

    /**
     * TranslateGemma: each turn names the source language; earlier pieces are
     * earlier turns. Its template puts a newline and eight spaces before each
     * earlier translation, and the model is given exactly that.
     */
    fun translateGemma(history: List<Piece>, source: String, text: String, target: String): String {
        fun turn(src: String, body: String): String {
            val s = name(src); val t = name(target)
            return "<start_of_turn>user\nYou are a professional $s ($src) to $t ($target) translator. " +
                "Your goal is to accurately convey the meaning and nuances of the original $s text while adhering to " +
                "$t grammar, vocabulary, and cultural sensitivities.\n" +
                "Produce only the $t translation, without any additional explanations or commentary. " +
                "Please translate the following $s text into $t:\n\n\n${body.trim()}<end_of_turn>\n"
        }
        val out = StringBuilder("<bos>")
        for (piece in history) {
            out.append(turn(piece.source, piece.text))
            out.append("<start_of_turn>model\n\n        ").append(piece.translation.trim()).append("<end_of_turn>\n")
        }
        out.append(turn(source, text)).append("<start_of_turn>model\n")
        return out.toString()
    }

    /** EuroLLM: its training format, one piece at a time. */
    fun euroLLM(source: String, text: String, target: String): String {
        val s = name(source); val t = name(target)
        return "<|im_start|>system\n<|im_end|>\n<|im_start|>user\n" +
            "Translate the following $s source text to $t:\n$s: $text\n$t: <|im_end|>\n<|im_start|>assistant\n"
    }
}
