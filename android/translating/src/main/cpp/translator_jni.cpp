// A model, its context and greedy decoding, for Kotlin. The context is kept
// between calls and only what changed since the last prompt is read, as the
// iPhone app's PromptCache does: on a phone reading the prompt costs as much
// as writing the answer.
#include <cstdlib>
#include <jni.h>
#include <android/log.h>
#include <string>
#include <vector>
#include <cstdio>
#include "llama.h"
#include "ggml-backend.h"

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "translator", __VA_ARGS__)

namespace {
struct Engine {
    llama_model* model = nullptr;
    llama_context* ctx = nullptr;
    const llama_vocab* vocab = nullptr;
    llama_sampler* sampler = nullptr;
    std::vector<llama_token> held;  // what the context holds, in order
};

std::vector<llama_token> tokenize(const llama_vocab* vocab, const std::string& text) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, false, true);
    std::vector<llama_token> tokens(n);
    llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, false, true);
    return tokens;
}

std::string utf8(JNIEnv* env, jbyteArray bytes) {
    jsize n = env->GetArrayLength(bytes);
    std::string out(n, '\0');
    env->GetByteArrayRegion(bytes, 0, n, reinterpret_cast<jbyte*>(out.data()));
    return out;
}

jbyteArray bytes(JNIEnv* env, const std::string& s) {
    jbyteArray out = env->NewByteArray((jsize) s.size());
    env->SetByteArrayRegion(out, 0, (jsize) s.size(), reinterpret_cast<const jbyte*>(s.data()));
    return out;
}
}

extern "C" JNIEXPORT void JNICALL
Java_com_snepssen_translating_LlamaNative_initialize(JNIEnv* env, jclass, jstring nativeLibDir) {
    // OpenMP's threads spin 200 ms after their work before sleeping, holding
    // the cores speech recognition waits for. Never sleeping (a passive wait)
    // costs more: a step syncs its threads hundreds of times. 20 ms keeps them
    // awake through a translation and lets go soon after. Read when OpenMP
    // starts, so set before the CPU backend loads.
    setenv("KMP_BLOCKTIME", "20", 0);
    const char* dir = env->GetStringUTFChars(nativeLibDir, nullptr);
    ggml_backend_load_all_from_path(dir);  // the best CPU variant this phone has
    env->ReleaseStringUTFChars(nativeLibDir, dir);
    llama_backend_init();
}

// noSpacePrefix: tokenize text after a special token without SentencePiece's
// leading "▁", as Hugging Face's tokenizer does for EuroLLM (legacy=False);
// its GGUF says add_space_prefix, and llama.cpp would then read "<|im_start|>
// system" as "▁system", a token the model never saw there in training.
extern "C" JNIEXPORT jlong JNICALL
Java_com_snepssen_translating_LlamaNative_load(JNIEnv* env, jclass, jstring path, jint contextSize, jint threads, jboolean noSpacePrefix) {
    const char* file = env->GetStringUTFChars(path, nullptr);
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    static llama_model_kv_override overrides[2] = {};
    if (noSpacePrefix) {
        overrides[0].tag = LLAMA_KV_OVERRIDE_TYPE_BOOL;
        std::snprintf(overrides[0].key, sizeof(overrides[0].key), "tokenizer.ggml.add_space_prefix");
        overrides[0].val_bool = false;
        overrides[1].key[0] = 0;
        mp.kv_overrides = overrides;
    }
    llama_model* model = llama_model_load_from_file(file, mp);
    env->ReleaseStringUTFChars(path, file);
    if (!model) return 0;
    auto cp = llama_context_default_params();
    cp.n_ctx = (uint32_t) contextSize;
    cp.n_batch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    llama_context* ctx = llama_init_from_model(model, cp);
    if (!ctx) { llama_model_free(model); return 0; }
    auto* engine = new Engine();
    engine->model = model;
    engine->ctx = ctx;
    engine->vocab = llama_model_get_vocab(model);
    engine->sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
    llama_sampler_chain_add(engine->sampler, llama_sampler_init_greedy());
    return reinterpret_cast<jlong>(engine);
}

extern "C" JNIEXPORT jintArray JNICALL
Java_com_snepssen_translating_LlamaNative_tokenize(JNIEnv* env, jclass, jlong handle, jbyteArray text) {
    auto* engine = reinterpret_cast<Engine*>(handle);
    auto tokens = tokenize(engine->vocab, utf8(env, text));
    jintArray out = env->NewIntArray((jsize) tokens.size());
    env->SetIntArrayRegion(out, 0, (jsize) tokens.size(), reinterpret_cast<const jint*>(tokens.data()));
    return out;
}

// Whether `out` holds a whole line worth saying: a non-empty line that has
// ended, and isn't one that only announces the next ("Here's the English
// translation:"), which Linguist.spoken skips.
static bool saidLine(const std::string& out) {
    size_t start = 0;
    while (true) {
        size_t text = out.find_first_not_of(" \n\t", start);
        if (text == std::string::npos) return false;
        size_t end = out.find('\n', text);
        if (end == std::string::npos) return false;
        size_t last = out.find_last_not_of(" \t\r", end - 1);
        if (out[last] != ':') return true;
        start = end + 1;
    }
}

// The prompt's continuation, greedy, until an end-of-generation token or
// maxTokens; with firstLine, also at the end of the first non-empty line. Only
// the first line of an answer is ever said (the apps' Linguist.spoken), and a
// small model that has answered may go on repeating the format for seconds.
extern "C" JNIEXPORT jbyteArray JNICALL
Java_com_snepssen_translating_LlamaNative_generate(JNIEnv* env, jclass, jlong handle, jbyteArray promptBytes, jint maxTokens, jboolean firstLine) {
    auto* engine = reinterpret_cast<Engine*>(handle);
    auto prompt = tokenize(engine->vocab, utf8(env, promptBytes));
    if (prompt.empty()) return bytes(env, "");
    size_t keep = 0;
    while (keep < engine->held.size() && keep < prompt.size() && engine->held[keep] == prompt[keep]) keep++;
    keep = std::min(keep, prompt.size() - 1);  // always read at least one token
    llama_memory_t memory = llama_get_memory(engine->ctx);
    if (!llama_memory_seq_rm(memory, 0, (llama_pos) keep, -1)) { llama_memory_clear(memory, true); keep = 0; }
    engine->held.assign(prompt.begin(), prompt.begin() + (long) keep);
    for (size_t i = keep; i < prompt.size(); i += 512) {
        int32_t n = (int32_t) std::min<size_t>(512, prompt.size() - i);
        if (llama_decode(engine->ctx, llama_batch_get_one(prompt.data() + i, n)) != 0) {
            llama_memory_clear(memory, true); engine->held.clear();
            return bytes(env, "");
        }
        engine->held.insert(engine->held.end(), prompt.begin() + (long) i, prompt.begin() + (long) i + n);
    }
    std::string out;
    char piece[256];
    for (int produced = 0; produced < maxTokens; produced++) {
        llama_token token = llama_sampler_sample(engine->sampler, engine->ctx, -1);
        if (llama_vocab_is_eog(engine->vocab, token)) break;
        int n = llama_token_to_piece(engine->vocab, token, piece, sizeof(piece), 0, false);
        if (n > 0) out.append(piece, n);
        if (firstLine && saidLine(out)) break;
        if (llama_decode(engine->ctx, llama_batch_get_one(&token, 1)) != 0) break;
        engine->held.push_back(token);
    }
    return bytes(env, out);
}

extern "C" JNIEXPORT void JNICALL
Java_com_snepssen_translating_LlamaNative_free(JNIEnv*, jclass, jlong handle) {
    auto* engine = reinterpret_cast<Engine*>(handle);
    llama_sampler_free(engine->sampler);
    llama_free(engine->ctx);
    llama_model_free(engine->model);
    delete engine;
}
