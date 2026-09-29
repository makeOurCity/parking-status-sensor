# #74 の計測結果（残っている分）

[Issue #74](https://github.com/makeOurCity/parking-status-sensor/issues/74)（ブラウンアウトの調査）の計測結果のうち、残っているもの。結論は [docs/74-brownout-conclusions.md](../../../../docs/74-brownout-conclusions.md)。

U200 高速ロガーの生の CSV（`capture-fast.csv`、`capture-fast-b1-76fix.csv`、`capture-fast-b2-76fix.csv`、`capture-60-pot.csv`、`capture-D.csv`）は git の管理外だったため、2026-09-29 にローカルリポジトリを消した際に失われた。ここにあるのは、それを解析した途中結果と、XIAO のシリアルログ。

## ファイル

| ファイル | 中身 |
|---|---|
| `cycles-battery1-20260927.txt` | 電池 #1、#76 修正前のファーム。起床 153 回分（09-27 00:38〜13:42 ごろ、約 13h） |
| `cycles-battery2-20260927-29.txt` | 電池 #2、#76 修正後のファーム。起床 526 回分（09-27 14:54〜09-29 11:38 ごろ、約 44.5h） |
| `xiao-serial-before-76fix-20260927.log` | #76 修正前。通常の送信（14:10）で切断処理に 35.8s かかったときのシリアルログ（時刻は Mac 側で付与） |
| `xiao-serial-after-76fix-20260927.log` | #76 修正後。ブートモードと通常の送信（14:27）のシリアルログ |

### cycles-*.txt の形式

`tools/power-logger/find_dips.py` の出力。1 行が 1 回の起床（`current_max_mA` が 10mA 以上のウィンドウが続く区間）。

| 列 | 意味 |
|---|---|
| `start_s` | 記録開始からの経過秒 |
| `dur_s` | 起きていた時間（秒） |
| `idle_mV` | 起床直前の待機時の電圧（U200 の `bus_avg_mV`） |
| `min_mV` | 起床中の最低電圧（`bus_min_mV`、約 0.46ms 間隔の最小値） |
| `drop_mV` | `idle_mV − min_mV` |
| `i_at_min_mA` | 最低電圧だったウィンドウの最大電流 |
| `peak_mA` | 起床中の最大電流（電流は約 4ms 間隔で間引いて読んでいる） |

`start_s` の 0 は、おおよそ次の時刻（CloudWatch の受信時刻から逆算、誤差は数秒）:

- 電池 #1: 2026-09-27 00:38:30 JST
- 電池 #2: 2026-09-27 14:54:07 JST

電圧はデバイスが受け取る電圧（U200 の OUT 側）で、テスターの値と一致することを確認済み。

## 今後の計測

生の CSV は、リポジトリの外に保存する（リポジトリを消したり作り直したりしても巻き込まれないように）。
