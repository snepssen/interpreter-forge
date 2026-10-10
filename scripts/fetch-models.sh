#!/bin/sh
# The translation model, fetched with curl into models/. The Hugging Face
# client can hang on large files on some machines; plain HTTPS doesn't.
# Parakeet and Silero download themselves on first use.
set -eu
cd "$(dirname "$0")/.."

REPO=mlx-community/Qwen3-4B-Instruct-2507-4bit
REV=50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b
DIR=models/qwen3-4b-instruct-2507-4bit
SHA=2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f  # model.safetensors

mkdir -p "$DIR"
for f in added_tokens.json chat_template.jinja config.json generation_config.json merges.txt \
         model.safetensors.index.json special_tokens_map.json tokenizer.json tokenizer_config.json \
         vocab.json model.safetensors; do
  [ -s "$DIR/$f" ] && [ "$f" != model.safetensors ] && continue
  echo "$f"
  curl -fL --retry 3 -C - -o "$DIR/$f" "https://huggingface.co/$REPO/resolve/$REV/$f"
done
echo "$SHA  $DIR/model.safetensors" | shasum -a 256 -c -
