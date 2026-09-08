#!/bin/zsh
# Снимок поповера Kelvin в PNG (по кадру на вкладку) — офскрин, БЕЗ Screen-Recording-TCC.
# Использует режим BM_SNAP (main.swift): рендерит content-view контроллера в bitmap, наполнив
# его живыми данными через невидимое окно + прогон тика. НЕ мешает установленной копии владельца.
#
# Использование:  ./snap.sh [выходной_каталог] [--light]
#   ./snap.sh                       → снимки в ./snaps (тёмная тема)
#   ./snap.sh /tmp/kshots           → в указанный каталог
#   ./snap.sh ./snaps --light       → светлая тема
set -e
cd "$(dirname "$0")"

OUTDIR="${1:-./snaps}"
[[ "$1" == "--light" ]] && OUTDIR="./snaps"
LIGHT=""
for a in "$@"; do [[ "$a" == "--light" ]] && LIGHT="1"; done

EXE="./Kelvin.app/Contents/MacOS/Kelvin"
if [[ ! -x "$EXE" ]]; then echo "нет бинаря $EXE — сначала ./build.sh"; exit 1; fi

mkdir -p "$OUTDIR"
rm -f "$OUTDIR"/*.png(N)

echo "→ снимаю поповер в $OUTDIR …"
# perl-alarm вместо GNU timeout (его нет на macOS): жёсткий предел, если рендер зависнет
if [[ -n "$LIGHT" ]]; then
  BM_SNAP="$OUTDIR" BM_LIGHT=1 perl -e 'alarm 60; exec @ARGV' "$EXE" || true
else
  BM_SNAP="$OUTDIR" perl -e 'alarm 60; exec @ARGV' "$EXE" || true
fi

echo "✓ готово:"
files=("$OUTDIR"/*.png(N))
if (( ${#files} )); then
  printf '%s\n' "${files[@]}"
else
  echo "  (PNG не создались — см. вывод выше)"
fi
