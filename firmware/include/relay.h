#pragma once

// #46: Grove 2-Coil Latching Relay 制御。LTE-M モジュールの5V線をリレー経由で
// 物理遮断する（Grove Shield のポートVCCはGPIOで直接オフにできないため）。
//
// リレーはパルスでのみ状態が切り替わり、保持中は電力を消費しない
// （Seeed 103020010、SIG1本をrising/falling edgeで駆動）。
// SET/RESETどちらの論理レベルがLTE ON/OFFに対応するかはベンチ実測が必要。
// kRelayOnLevel（relay.cpp）を1箇所直せば極性を反転できる。

// GPIO初期化。反射的に一度RESETパルスを送り、LTE-Mを確実にOFFへ倒す
// （ウォッチドッグリセット後もリレーがONのまま固定されないためのフェイルセーフ、
// setup() の一番最初、他のどの処理よりも前に呼ぶこと）。
void initRelay();

// SETパルス送信（LTE-Mへ通電）。
void relayLteOn();

// RESETパルス送信（LTE-M遮断）。
void relayLteOff();
