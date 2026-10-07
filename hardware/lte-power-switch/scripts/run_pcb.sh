#!/bin/sh
# 基板を再生成して DRC (回路図との整合込み) を実行する
cd "$(dirname "$0")/.." || exit 1
KP=/Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3
K=/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli
$KP scripts/gen_pcb.py 2>&1 | grep -v assert
$K pcb drc --severity-all --schematic-parity --format report -o ${DRC_OUT:-/tmp/drc.rpt} lte-power-switch.kicad_pcb
