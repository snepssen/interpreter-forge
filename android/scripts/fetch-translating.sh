#!/usr/bin/env bash
# The translators as GGUF for llama.cpp, Q4_K_M: TranslateGemma 4B (the
# standard) and EuroLLM 1.7B (only where nothing better fits). mradermacher's
# quantisations, pinned to a revision and held to Hugging Face's SHA-256.
set -euo pipefail
cd "$(dirname "$0")/../../models/android"

fetch() {  # repo revision file sha256
  local repo=$1 rev=$2 file=$3 sum=$4
  if [ ! -s "$file" ]; then
    curl -fL --progress-bar -o "$file.part" "https://huggingface.co/$repo/resolve/$rev/$file"
    mv "$file.part" "$file"
  fi
  echo "$sum  $file" | shasum -a 256 -c --status || { echo "error: $file does not match its SHA-256" >&2; exit 1; }
  echo "$file: verified"
}

fetch mradermacher/translategemma-4b-it-GGUF d37868f759d2f817a43d28dd80cf9f982ffa62fd \
  translategemma-4b-it.Q4_K_M.gguf 81200d03e843d2ec1ece6eeafe7d13cb6e5211e1fcd336ade55790b683a08330
fetch mradermacher/EuroLLM-1.7B-Instruct-GGUF 2951f08f66429c934c8b01a94347161362430808 \
  EuroLLM-1.7B-Instruct.Q4_K_M.gguf 1cade17f491ea46a686dbee51fbd52442e0f001f102380c3b9d66b4a77f84093
