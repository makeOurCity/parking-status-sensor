"""decode.py のテスト。test_vectors.json の hex は firmware の encodeLoRaWanCore() の出力。"""

import base64
import json
from pathlib import Path

import pytest

from decode import decode_core, decode_message

VECTORS = json.loads((Path(__file__).parent / "test_vectors.json").read_text(encoding="utf-8"))


@pytest.mark.parametrize("vector", VECTORS, ids=[v["name"] for v in VECTORS])
def test_decode_core(vector):
    assert decode_core(bytes.fromhex(vector["hex"])) == vector["decoded"]


def test_decode_message_envelope():
    vector = VECTORS[0]
    message = {
        "WirelessDeviceId": "73742d6b-b4bd-426a-af5b-83412752b8a6",
        "PayloadData": base64.b64encode(bytes.fromhex(vector["hex"])).decode(),
        "WirelessMetadata": {
            "LoRaWAN": {"FPort": 1, "DataRate": "2", "FCnt": 7, "Timestamp": "2026-10-01T06:00:00Z"}
        },
    }
    result = decode_message(message)
    assert result["status"] == "open"
    assert result["fCnt"] == 7
    assert result["receivedAt"] == "2026-10-01T06:00:00Z"


def test_rejects_wrong_length():
    with pytest.raises(ValueError, match="18 bytes"):
        decode_core(bytes(13))


def test_rejects_unknown_version():
    with pytest.raises(ValueError, match="version"):
        decode_core(bytes([0x80]) + bytes(17))


def test_rejects_other_fport():
    message = {"PayloadData": "", "WirelessMetadata": {"LoRaWAN": {"FPort": 2}}}
    with pytest.raises(ValueError, match="fPort"):
        decode_message(message)
