# tools/lorawan

LoRaWAN（Grove Wio-E5、#40）のコアペイロードのデコーダ。バイト配置は [docs/40-lorawan-design.md](../../docs/40-lorawan-design.md) §3。

## 使い方

```bash
cd tools/lorawan
python3 decode.py 5201000C0012000300403400640000000121   # 16 進
python3 decode.py --base64 UgEADAASAAMAQDQAZAAAAAEh         # PayloadData
python3 decode.py --message message.json                # Destination に届いた JSON（- で stdin）
```

デコーダは標準ライブラリだけで動く。

## テスト

初回だけ venv を作る（`.venv` は Git 管理外）。

```bash
cd tools/lorawan
python3 -m venv .venv
./.venv/bin/pip install pytest
./.venv/bin/python -m pytest
```

`test_vectors.json` の `hex` は、ファームの `encodeLoRaWanCore()`（`firmware/src/lorawan_payload.cpp`）の出力。エンコーダを変えたら、ベクタも作り直す。
