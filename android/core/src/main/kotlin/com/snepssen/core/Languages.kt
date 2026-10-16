package com.snepssen.core

/**
 * The languages Parakeet transcribes, and what the text of a piece says about
 * which of them it is in. The iPhone app's Languages, ported.
 */
object Languages {
    val names = mapOf(
        "bg" to "Bulgarian", "cs" to "Czech", "da" to "Danish", "de" to "German", "el" to "Greek", "en" to "English",
        "es" to "Spanish", "et" to "Estonian", "fi" to "Finnish", "fr" to "French", "hr" to "Croatian", "hu" to "Hungarian",
        "it" to "Italian", "lt" to "Lithuanian", "lv" to "Latvian", "mt" to "Maltese", "nl" to "Dutch", "pl" to "Polish",
        "pt" to "Portuguese", "ro" to "Romanian", "ru" to "Russian", "sk" to "Slovak", "sl" to "Slovenian", "sv" to "Swedish",
        "uk" to "Ukrainian",
    )
    private val scripts = mapOf("bg" to "CYRILLIC", "ru" to "CYRILLIC", "uk" to "CYRILLIC", "el" to "GREEK")  // others: LATIN

    /** Letters that all but give a language away; á, é, ö... are shared too widely. */
    private val letters: Map<String, Set<Char>> = mapOf(
        "pl" to "łąęśźć", "hu" to "őű", "cs" to "řěů", "sk" to "ľĺŕ", "ro" to "ășț", "es" to "ñ¿¡",
        "pt" to "ãõ", "de" to "ß", "fr" to "œ", "da" to "æø", "lt" to "ėįųū", "lv" to "āēīūļņķģ", "mt" to "ħġ",
    ).mapValues { it.value.toSet() }

    /** Everyday words English doesn't share: "nem", "tudom" mark Hungarian even when the rest came out garbled. */
    private val words: Map<String, Set<String>> = mapOf(
        "pl" to setOf("nie", "tak", "jest", "że", "się", "ale", "czy", "już", "jak", "tylko", "mnie", "wiesz",
                      "dobra", "dobrze", "teraz", "jestem", "jesteś", "mówię", "może", "tego", "tym", "był", "była"),
        "hu" to setOf("nem", "igen", "hogy", "egy", "meg", "csak", "van", "nincs", "tudom", "azt", "és", "már",
                      "akkor", "persze", "nagyon", "szia", "mert", "vagy", "volt", "lesz", "itt", "ott", "nekem"),
        "nl" to setOf("ik", "het", "een", "niet", "dat", "wat", "maar", "ook", "nog", "toch", "zijn", "heb",
                      "hebt", "jij", "wij", "geen", "veel", "gezellig", "lekker", "kijk", "zeg"),
    )

    /** "Polish, Hungarian and Dutch" for ["pl", "hu", "nl"]. */
    fun list(codes: List<String>, names: Map<String, String> = this.names): String {
        val words = codes.mapNotNull { names[it] }
        if (words.size <= 1) return words.firstOrNull() ?: ""
        return words.dropLast(1).joinToString(", ") + " and " + words.last()
    }

    /** What the text itself says about being in one of `codes`: true, false, or null when the model has to be asked. */
    fun evidence(text: String, codes: List<String>): Boolean? {
        if (!codes.all { names[it] != null }) return null
        val expected = codes.map { scripts[it] ?: "LATIN" }.toSet()
        val lower = text.lowercase()
        val found = lower.filter { it.isLetter() }
        if (found.count { script(it) !in expected } >= 2) return false  // Cyrillic for Polish, say
        val letterSet = found.toSet()
        val wordSet = lower.split(Regex("[^\\p{L}\\p{N}_]+")).filter { it.isNotEmpty() }.toSet()
        if (codes.any { (letters[it] ?: emptySet()).any(letterSet::contains) || (words[it] ?: emptySet()).any(wordSet::contains) }) return true
        if (letters.any { (code, set) -> code !in codes && set.any(letterSet::contains) }) return false  // ã, ñ, ß... and nothing of ours
        return null
    }

    private fun script(ch: Char) = Character.getName(ch.code)?.substringBefore(' ') ?: ""
}
