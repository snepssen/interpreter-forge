#!/usr/bin/env bash
# Print the newest polyglot snepssen export (the .onnx; its .onnx.json sits
# beside it) from voice-polyglot beside translate-core, or fail.
#
# Training exports a milestone every 25 epochs into
# voice-polyglot/work/runs/polyglot/exports/epoch-NNN/; the builds bundle the
# newest one as snepssen-polyglot.onnx, so a better-trained voice is a rebuild
# away. Folders with a suffix (epoch-047-before-retrim) are not milestones.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
EXPORTS="$(dirname "$REPO")/voice-polyglot/work/runs/polyglot/exports"
for dir in $(ls -d "$EXPORTS"/epoch-* 2>/dev/null | grep -E '/epoch-[0-9]+$' | sort -r); do
  model="$dir/snepssen-polyglot-$(basename "$dir").onnx"
  if [ -s "$model" ] && [ -s "$model.json" ]; then echo "$model"; exit 0; fi
done
echo "error: no polyglot voice export in $EXPORTS (voice-polyglot beside translate-core?)" >&2
exit 1
