"""LoRaWAN の正規化とハンドラのテスト。

test_vectors.json の hex（ファームのエンコーダの出力）から Destination のメッセージを組み立てる。
"""

import base64
import json
import logging
import re
import sys
from pathlib import Path
from unittest import mock

import pytest

import handler
import lorawan

REPO_ROOT = Path(__file__).resolve().parent.parent
VECTORS = json.loads((REPO_ROOT / "tools/lorawan/test_vectors.json").read_text(encoding="utf-8"))

WIRELESS_DEVICE_ID = "73742d6b-b4bd-426a-af5b-83412752b8a6"
DEVICE_NAME = "xiao-e83dc1fc1aec"


def make_message(hex_payload: str, **overrides) -> dict:
    message = {
        "WirelessDeviceId": WIRELESS_DEVICE_ID,
        "PayloadData": base64.b64encode(bytes.fromhex(hex_payload)).decode(),
        "WirelessMetadata": {
            "LoRaWAN": {
                "DevEui": "2cf7f1207380e5f9",
                "FPort": 1,
                "FCnt": 3,
                "DataRate": "5",
                "SpreadingFactor": 7,
                "Frequency": "922600000",
                "MType": "ConfirmedDataUp",
                "Gateways": [{"GatewayEui": "2cf7f1138030000c", "Rssi": -46, "Snr": 13.25}],
                "Timestamp": "2026-10-01T07:47:49Z",
            }
        },
    }
    message.update(overrides)
    return message


class FakeIotWireless:
    """boto3 の iotwireless クライアントの代わり。"""

    class exceptions:
        class ResourceNotFoundException(Exception):
            pass

    def __init__(self, name=DEVICE_NAME, missing=False):
        self.name = name
        self.missing = missing
        self.calls = []

    def get_wireless_device(self, **kwargs):
        self.calls.append(kwargs)
        if self.missing:
            raise self.exceptions.ResourceNotFoundException("not found")
        return {"Name": self.name} if self.name is not None else {}


@pytest.fixture
def fake_client(monkeypatch):
    client = FakeIotWireless()
    monkeypatch.setattr(lorawan, "_client", lambda: client)
    return client


def telemetry_lines(caplog) -> list[str]:
    return [r.getMessage() for r in caplog.records if "telemetry received" in r.getMessage()]


# --- デコーダ ---------------------------------------------------------------


@pytest.mark.parametrize("vector", VECTORS, ids=[v["name"] for v in VECTORS])
def test_decode_core_matches_vectors(vector):
    assert lorawan.decode_core(bytes.fromhex(vector["hex"])) == vector["decoded"]


@pytest.mark.parametrize("vector", VECTORS, ids=[v["name"] for v in VECTORS])
def test_decode_core_matches_tools_decoder(vector):
    """bridge の複製が tools/lorawan/decode.py とずれていないこと。"""
    sys.path.insert(0, str(REPO_ROOT / "tools/lorawan"))
    try:
        import decode
    finally:
        sys.path.remove(str(REPO_ROOT / "tools/lorawan"))
    payload = bytes.fromhex(vector["hex"])
    assert lorawan.decode_core(payload) == decode.decode_core(payload)


def test_decode_core_reserved_values_match_tools_decoder():
    sys.path.insert(0, str(REPO_ROOT / "tools/lorawan"))
    try:
        import decode
    finally:
        sys.path.remove(str(REPO_ROOT / "tools/lorawan"))
    # status=3 / reason 範囲内 / prevOutcome=7 / resetReason=15 / wakeCause=15
    payload = bytes([0x70, 0xE0]) + bytes(15) + bytes([0xFF])
    assert lorawan.decode_core(payload) == decode.decode_core(payload)


# --- 正規化 -----------------------------------------------------------------


def test_build_telemetry_shape():
    vector = VECTORS[0]
    message = make_message(vector["hex"])
    telemetry = lorawan.build_telemetry(message, lorawan.decode_uplink(message), DEVICE_NAME)

    assert telemetry == {
        "deviceId": DEVICE_NAME,
        "status": "open",
        "raw": {"red": 12, "green": 18, "blue": 3, "clear": 64},
        "threshold": 100,
        "determinedBy": "device",
        "timestamp": "2026-10-01T07:47:49Z",
        "power": {"bootCount": 1, "resetReason": "power_on", "wakeCause": "power_on"},
        "network": {
            "transport": "lorawan",
            "rssi": -46,
            "snr": 13.25,
            "dataRate": 5,
            "fCnt": 3,
            "frequency": 922600000,
        },
        "sync": {"prevOutcome": "none", "prevAttempts": 0, "prevActiveMs": 13000},
        "lorawan": {
            "reason": "state_change",
            "coldBoot": True,
            "bootSlot": 1,
            "wirelessDeviceId": WIRELESS_DEVICE_ID,
            "devEui": "2cf7f1207380e5f9",
        },
    }
    # LTE-M 版と同じキーの並び（先頭から）
    assert list(telemetry)[:7] == ["deviceId", "status", "raw", "threshold", "determinedBy", "timestamp", "power"]


def test_build_telemetry_without_gateways():
    message = make_message(VECTORS[0]["hex"])
    del message["WirelessMetadata"]["LoRaWAN"]["Gateways"]
    telemetry = lorawan.build_telemetry(message, lorawan.decode_uplink(message), DEVICE_NAME)
    assert telemetry["network"]["rssi"] is None
    assert telemetry["network"]["snr"] is None


# --- ハンドラ（LoRaWAN） ----------------------------------------------------


def test_handler_logs_telemetry_line(fake_client, caplog):
    caplog.set_level(logging.INFO)
    message = make_message(VECTORS[0]["hex"])

    result = handler.handler(message, None)

    assert json.loads(result["body"]) == {
        "ok": True,
        "deviceId": DEVICE_NAME,
        "status": "open",
        "orion": "disabled",
    }
    lines = telemetry_lines(caplog)
    assert len(lines) == 1
    prefix, _, body = lines[0].partition(": ")
    assert prefix == "parking-status telemetry received"
    telemetry = json.loads(body)
    assert telemetry["deviceId"] == DEVICE_NAME
    assert telemetry["network"]["transport"] == "lorawan"
    assert fake_client.calls == [{"Identifier": WIRELESS_DEVICE_ID, "IdentifierType": "WirelessDeviceId"}]


def test_handler_raw_line_does_not_match_viewer_filter(fake_client, caplog):
    caplog.set_level(logging.INFO)
    handler.handler(make_message(VECTORS[0]["hex"]), None)

    raw_lines = [r.getMessage() for r in caplog.records if r.getMessage().startswith("lorawan uplink raw: ")]
    assert len(raw_lines) == 1
    assert "telemetry received" not in raw_lines[0]
    assert json.loads(raw_lines[0].removeprefix("lorawan uplink raw: "))["WirelessDeviceId"] == WIRELESS_DEVICE_ID


def test_handler_log_line_parses_like_ios_app(fake_client, caplog):
    """CloudWatchLogsService.swift の parse 正規表現が期待どおりに取れること。"""
    caplog.set_level(logging.INFO)
    handler.handler(make_message(VECTORS[0]["hex"]), None)
    line = telemetry_lines(caplog)[0]

    def first(pattern):
        match = re.search(pattern, line)
        return match.group(1) if match else None

    assert first(r'"deviceId":\s*"([^"]+)"') == DEVICE_NAME
    assert first(r'"status":\s*"([^"]+)"') == "open"
    assert first(r'"bootCount":\s*(\d+)') == "1"
    assert first(r'"transport":\s*"([^"]+)"') == "lorawan"
    # TelemetryPayload が読むキー
    payload = json.loads(line[line.index("{") :])
    assert set(payload["raw"]) == {"red", "green", "blue", "clear"}
    assert set(payload["power"]) == {"bootCount", "resetReason", "wakeCause"}


def test_device_name_is_cached_per_container(fake_client):
    message = make_message(VECTORS[0]["hex"])
    handler.handler(message, None)
    handler.handler(message, None)
    assert len(fake_client.calls) == 1


@pytest.mark.parametrize(
    "mutate, expected",
    [
        (lambda m: m["WirelessMetadata"]["LoRaWAN"].update(FPort=2), "fPort"),
        (lambda m: m.update(PayloadData=base64.b64encode(bytes(13)).decode()), "18 bytes"),
        (lambda m: m.update(PayloadData=base64.b64encode(bytes([0x80]) + bytes(17)).decode()), "version"),
        (lambda m: m.update(PayloadData="!!!not base64!!!"), "base64"),
        (lambda m: m.pop("PayloadData"), "PayloadData"),
    ],
    ids=["fport", "length", "version", "base64", "missing"],
)
def test_handler_decode_failure_logs_error_and_succeeds(fake_client, caplog, mutate, expected):
    caplog.set_level(logging.INFO)
    message = make_message(VECTORS[0]["hex"])
    mutate(message)

    result = handler.handler(message, None)

    assert result["statusCode"] == 200
    body = json.loads(result["body"])
    assert body["ok"] is False and expected in body["error"]
    assert telemetry_lines(caplog) == []
    errors = [r for r in caplog.records if r.levelno == logging.ERROR]
    assert len(errors) == 1 and expected in errors[0].getMessage()
    assert fake_client.calls == []  # 不正なペイロードでは AWS API を呼ばない


def test_handler_unknown_wireless_device_logs_error(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(lorawan, "_client", lambda: FakeIotWireless(missing=True))

    result = handler.handler(make_message(VECTORS[0]["hex"]), None)

    assert json.loads(result["body"])["ok"] is False
    assert telemetry_lines(caplog) == []
    assert any(r.levelno == logging.ERROR for r in caplog.records)


def test_handler_nameless_wireless_device_logs_error(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(lorawan, "_client", lambda: FakeIotWireless(name=None))

    result = handler.handler(make_message(VECTORS[0]["hex"]), None)

    assert json.loads(result["body"])["ok"] is False
    assert telemetry_lines(caplog) == []


def test_handler_propagates_unexpected_aws_errors(monkeypatch):
    """権限不足などは例外のまま上げて、Lambda の非同期再試行に任せる。"""

    class Broken(FakeIotWireless):
        def get_wireless_device(self, **kwargs):
            raise RuntimeError("AccessDenied")

    monkeypatch.setattr(lorawan, "_client", lambda: Broken())
    with pytest.raises(RuntimeError):
        handler.handler(make_message(VECTORS[0]["hex"]), None)


# --- ハンドラ（LTE-M / 従来） ----------------------------------------------


LTE_EVENT = {
    "deviceId": "xiao-e83dc1fb05fc",
    "status": "full",
    "raw": {"red": 150, "green": 820, "blue": 200, "clear": 1200},
    "threshold": 100,
    "determinedBy": "device",
    "timestamp": "2026-06-17T12:00:00Z",
    "power": {"bootCount": 5, "wakeCause": "timer", "resetReason": "deep_sleep"},
    "network": {"transport": "lte"},
}


def test_lte_event_is_logged_unchanged(caplog, monkeypatch):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(lorawan, "_client", mock.Mock(side_effect=AssertionError("must not call AWS")))

    result = handler.handler(LTE_EVENT, None)

    assert caplog.records[0].getMessage() == "parking-status telemetry received: " + json.dumps(
        LTE_EVENT, ensure_ascii=False
    )
    assert len(telemetry_lines(caplog)) == 1
    assert json.loads(result["body"]) == {
        "ok": True,
        "deviceId": "xiao-e83dc1fb05fc",
        "status": "full",
        "orion": "disabled",
    }


def test_event_without_fields_is_still_handled(caplog):
    caplog.set_level(logging.INFO)
    result = handler.handler({}, None)
    assert json.loads(result["body"])["deviceId"] == "unknown"
    assert len(telemetry_lines(caplog)) == 1
