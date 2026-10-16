// The three espeak-ng calls voice-core's EspeakPhonemizer makes, for Kotlin.
// The clause terminator constants and their masking are copied from voice-core
// (which copied them from piper1-gpl's espeakbridge.c) exactly: getting the bit
// arithmetic subtly wrong would misplace sentence boundaries silently.
#include <jni.h>
#include <string>
#include <cstdlib>
#include <cstring>
#include <espeak-ng/speak_lib.h>

namespace {
constexpr int intonationFullStop = 0x00000000, intonationComma = 0x00001000,
              intonationQuestion = 0x00002000, intonationExclamation = 0x00003000;
constexpr int typeClause = 0x00040000, typeSentence = 0x00080000;
constexpr int clausePeriod = 40 | intonationFullStop | typeSentence;
constexpr int clauseQuestion = 40 | intonationQuestion | typeSentence;
constexpr int clauseExclamation = 45 | intonationExclamation | typeSentence;
constexpr int clauseComma = 20 | intonationComma | typeClause;
constexpr int clauseColon = 30 | intonationFullStop | typeClause;
constexpr int clauseSemicolon = 30 | intonationComma | typeClause;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_snepssen_voice_EspeakNative_initialize(JNIEnv* env, jclass, jstring dataPath) {
    const char* path = env->GetStringUTFChars(dataPath, nullptr);
    int result = espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, path, 0);
    env->ReleaseStringUTFChars(dataPath, path);
    return result;
}

extern "C" JNIEXPORT jint JNICALL
Java_com_snepssen_voice_EspeakNative_setVoice(JNIEnv* env, jclass, jstring name) {
    const char* voice = env->GetStringUTFChars(name, nullptr);
    int status = espeak_SetVoiceByName(voice);
    env->ReleaseStringUTFChars(name, voice);
    return status;
}

// Clauses as one string: phonemes \x1f terminator \x1f endOfSentence(0/1) \x1e ...
extern "C" JNIEXPORT jstring JNICALL
Java_com_snepssen_voice_EspeakNative_clauses(JNIEnv* env, jclass, jstring text) {
    const char* utf8 = env->GetStringUTFChars(text, nullptr);
    char* buffer = strdup(utf8);
    env->ReleaseStringUTFChars(text, utf8);
    std::string out;
    const void* cursor = buffer;
    while (cursor != nullptr) {
        int terminator = 0;
        const char* phonemes = espeak_TextToPhonemesWithTerminator(&cursor, espeakCHARS_AUTO, espeakPHONEMES_IPA, &terminator);
        if (phonemes == nullptr) break;
        int masked = terminator & 0x000FFFFF;
        const char* mark = "";
        switch (masked) {
            case clausePeriod: mark = "."; break;
            case clauseQuestion: mark = "?"; break;
            case clauseExclamation: mark = "!"; break;
            case clauseComma: mark = ","; break;
            case clauseColon: mark = ":"; break;
            case clauseSemicolon: mark = ";"; break;
            default: break;
        }
        bool end = (terminator & typeSentence) == typeSentence;
        out += phonemes; out += '\x1f'; out += mark; out += '\x1f'; out += end ? '1' : '0'; out += '\x1e';
    }
    free(buffer);
    return env->NewStringUTF(out.c_str());
}
