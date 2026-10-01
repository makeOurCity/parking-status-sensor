#!/usr/bin/env python3
"""#40: LoRaWAN コアペイロード（fPort 1, ver 1, 11 バイト）のデコーダ。

バイト配置は docs/40-lorawan-design.md §3。エンコーダは
firmware/src/lorawan_payload.cpp。AWS IoT Core for LoRaWAN の Destination に届く
メッセージの PayloadData（base64）か、16 進文字列を渡す。

    python3 decode.py 5A00000C0012000300400034
    python3 decode.py --base64 WgAADAASAAMAQAA0
    python3 decode.py --message message.json   # Destination に届いた JSON をそのまま
"""

import argparse
import base64
import json
import sys

CORE_FPORT = 1
CORE_SIZE = 11

STATUS = ["full", "available", "unknown"]
REASON = ["state_change", "heartbeat", "pending_retry", "boot_mode"]
OUTCOME = [
    "none",
    "confirmed",
    "connect_failed",
    "publish_failed",
    "budget_exhausted",
    "sensor_error",
    "skipped",
]


def _lookup(table, index):
    return table[index] if index < len(table) else f"reserved({index})"


def decode_core(payload: bytes) -> dict:
    if len(payload) != CORE_SIZE:
        raise ValueError(f"core payload must be {CORE_SIZE} bytes, got {len(payload)}")
    b0, b1 = payload[0], payload[1]
    version = b0 >> 6
    if version != 1:
        raise ValueError(f"unsupported payload version {version}")

    def u16(offset):
        return payload[offset] << 8 | payload[offset + 1]

    return {
        "version": version,
        "status": _lookup(STATUS, (b0 >> 4) & 0x3),
        "reason": _lookup(REASON, (b0 >> 2) & 0x3),
        "coldBoot": bool((b0 >> 1) & 0x1),
        "prevOutcome": _lookup(OUTCOME, b1 >> 5),
        "prevAttempts": (b1 >> 3) & 0x3,
        "bootSlot": b1 & 0x7,
        "raw": {"red": u16(2), "green": u16(4), "blue": u16(6), "white": u16(8)},
        "prevActiveMs": payload[10] * 250,
    }


def decode_message(message: dict) -> dict:
    """Destination に届く JSON（PayloadData + WirelessMetadata）をデコードする。"""
    lorawan = message.get("WirelessMetadata", {}).get("LoRaWAN", {})
    fport = lorawan.get("FPort")
    if fport is not None and fport != CORE_FPORT:
        raise ValueError(f"unsupported fPort {fport}")
    result = decode_core(base64.b64decode(message["PayloadData"]))
    result["wirelessDeviceId"] = message.get("WirelessDeviceId")
    result["receivedAt"] = lorawan.get("Timestamp")
    result["dataRate"] = lorawan.get("DataRate")
    result["fCnt"] = lorawan.get("FCnt")
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("hex", nargs="?", help="16 進文字列")
    group.add_argument("--base64", help="PayloadData（base64）")
    group.add_argument("--message", help="Destination に届いた JSON ファイル（- で stdin）")
    args = parser.parse_args(argv)

    if args.message:
        fp = sys.stdin if args.message == "-" else open(args.message, encoding="utf-8")
        with fp:
            result = decode_message(json.load(fp))
    elif args.base64:
        result = decode_core(base64.b64decode(args.base64))
    else:
        result = decode_core(bytes.fromhex(args.hex))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
