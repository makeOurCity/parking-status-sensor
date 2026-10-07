#pragma once

// #46: Grove 2-Coil Latching Relay 制御。LTE-M モジュールの5V線をリレー経由で
// 物理遮断する（Grove Shield のポートVCCはGPIOで直接オフにできないため）。
//
// リレーはパルスでのみ状態が切り替わり、保持中は電力を消費しない
// （Seeed 103020010、SIG1本をrising/falling edgeで駆動）。
// SET/RESETどちらの論理レベルがLTE ON/OFFに対応するかはベンチ実測が必要。
// kRelayOnLevel（relay.cpp）を1箇所直せば極性を反転できる。
//
// 注意（#90、docs/25-low-power-phase2-hardware-cutoff.md §2.2 の訂正を参照）:
// - このリレーのコイルは5V定格（Seeed Wiki: 動作電圧4.7〜5.3V、Set/Reset電圧は
//   最大4.0V）。Grove ポートのVCCは Shield の3V3レール（約3.33V）なので、定格を
//   下回る電圧で駆動している。SETコイルは基板上のダイオードの降下ぶんさらに不利。
//   根拠は回路図からの見積りで、実測は未確認（#88）。
// - 基板のLEDが光ることは、コイルに十分な電流が流れた証拠にならない
//   （LEDはコイルと別の経路）。
// - コイルの通電幅は基板側のRC回路で決まる（見積りで約43〜55ms）。
//   PSS_RELAY_PULSE_MS はそれを決めない。SETとRESETの間隔は150ms以上空けること。

// GPIO初期化。反射的に一度RESETパルスを送り、LTE-Mを確実にOFFへ倒す
// （ウォッチドッグリセット後もリレーがONのまま固定されないためのフェイルセーフ、
// setup() の一番最初、他のどの処理よりも前に呼ぶこと）。
void initRelay();

// SETパルス送信（LTE-Mへ通電）。
void relayLteOn();

// RESETパルス送信（LTE-M遮断）。
void relayLteOff();
