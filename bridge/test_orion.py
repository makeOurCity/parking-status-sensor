"""Orion 連携（#7）のテスト: NGSIv2 変換・デバイスマスター・Orion クライアント・ハンドラの組み込み。

AWS と Orion には接続しない（DynamoDB クライアントと `urlopen` はモック）。
"""

import json
import logging
import urllib.error

import pytest

import device_master
import handler
import lorawan
import ngsi
import cognito_auth
import orion
from test_lorawan import LTE_EVENT, VECTORS, FakeIotWireless, make_message, telemetry_lines

MASTER = device_master.DeviceMaster(device_id="xiao-e83dc1fb05fc", name="佐賀市役所第1駐車場", lat=33.2629, lon=130.3008)
NOW = "2026-10-06T00:00:00Z"

# data-model.md の「エンティティ例」
EXPECTED_ENTITY = {
    "id": "urn:ngsi:ParkingStatusSensor:xiao-e83dc1fb05fc",
    "type": "ParkingStatusSensor",
    "name": {"type": "Text", "value": "佐賀市役所第1駐車場"},
    "status": {
        "type": "Text",
        "value": "full",
        "metadata": {"label": {"type": "Text", "value": "満"}},
    },
    "rawSensor": {"type": "StructuredValue", "value": {"red": 150, "green": 820, "blue": 200, "clear": 1200}},
    "determinedBy": {"type": "Text", "value": "device"},
    "threshold": {"type": "Number", "value": 100},
    "deviceId": {"type": "Text", "value": "xiao-e83dc1fb05fc"},
    "location": {"type": "geo:json", "value": {"type": "Point", "coordinates": [130.3008, 33.2629]}},
    "dateObserved": {"type": "DateTime", "value": "2026-06-17T12:00:00Z"},
}


# --- ngsi.build_entity ------------------------------------------------------


def test_build_entity_matches_data_model():
    assert ngsi.build_entity(LTE_EVENT, MASTER, NOW) == EXPECTED_ENTITY


def test_build_entity_drops_diagnostic_fields():
    telemetry = {
        **LTE_EVENT,
        "sync": {"prevOutcome": "confirmed"},
        "bootMode": {"active": False, "slot": 0, "totalSlots": 0},
        "pot": {"enabled": False, "adcRaw": 0},
        "lorawan": {"reason": "heartbeat"},
    }
    entity = ngsi.build_entity(telemetry, MASTER, NOW)
    assert set(entity) == set(EXPECTED_ENTITY)
    for key in ("sync", "network", "bootMode", "pot", "power", "lorawan"):
        assert key not in entity


@pytest.mark.parametrize(
    "sent, expected",
    [("available", "open"), ("open", "open"), ("full", "full"), ("unknown", "unknown"), ("???", "unknown"), (None, "unknown")],
)
def test_status_is_normalized(sent, expected):
    entity = ngsi.build_entity({**LTE_EVENT, "status": sent}, MASTER, NOW)
    assert entity["status"]["value"] == expected
    assert entity["status"]["metadata"]["label"]["value"] == ngsi.STATUS_LABELS[expected]


def test_location_is_longitude_first():
    entity = ngsi.build_entity(LTE_EVENT, MASTER, NOW)
    assert entity["location"]["value"]["coordinates"] == [MASTER.lon, MASTER.lat]


def test_date_observed_falls_back_to_receive_time():
    telemetry = {k: v for k, v in LTE_EVENT.items() if k != "timestamp"}
    assert ngsi.build_entity(telemetry, MASTER, NOW)["dateObserved"]["value"] == NOW
    telemetry["timestamp"] = None  # LoRaWAN でゲートウェイの時刻が無いとき
    assert ngsi.build_entity(telemetry, MASTER, NOW)["dateObserved"]["value"] == NOW


def test_absent_optional_fields_are_omitted():
    entity = ngsi.build_entity({"deviceId": "xiao-e83dc1fb05fc", "status": "open"}, MASTER, NOW)
    assert not {"rawSensor", "threshold", "determinedBy"} & set(entity)


@pytest.mark.parametrize(
    "telemetry, expected",
    [({"status": "open"}, "deviceId"), ({"deviceId": "", "status": "open"}, "deviceId"), ({"deviceId": "x"}, "status")],
)
def test_build_entity_requires_device_id_and_status(telemetry, expected):
    with pytest.raises(ValueError, match=expected):
        ngsi.build_entity(telemetry, MASTER, NOW)


# --- device_master ----------------------------------------------------------


def dynamo_item(**overrides):
    item = {
        "deviceId": {"S": "xiao-e83dc1fb05fc"},
        "name": {"S": "佐賀市役所第1駐車場"},
        "lat": {"N": "33.2629"},
        "lon": {"N": "130.3008"},
        "enabled": {"BOOL": True},
    }
    item.update(overrides)
    return {k: v for k, v in item.items() if v is not None}


class FakeDynamo:
    def __init__(self, item=None, error=None):
        self.item = item
        self.error = error
        self.calls = []

    def get_item(self, **kwargs):
        self.calls.append(kwargs)
        if self.error:
            raise self.error
        return {"Item": self.item} if self.item else {}


def test_parse_item():
    assert device_master.parse_item("xiao-e83dc1fb05fc", dynamo_item()) == MASTER


def test_parse_item_enabled_defaults_to_true_and_can_be_false():
    assert device_master.parse_item("x", dynamo_item(enabled=None)).enabled is True
    assert device_master.parse_item("x", dynamo_item(enabled={"BOOL": False})).enabled is False


@pytest.mark.parametrize(
    "overrides",
    [
        {"name": None},
        {"name": {"S": "  "}},
        {"lat": None},
        {"lon": {"N": "abc"}},
        {"lat": {"N": "91"}},
        {"lon": {"N": "-181"}},
    ],
    ids=["no-name", "blank-name", "no-lat", "bad-lon", "lat-range", "lon-range"],
)
def test_parse_item_rejects_invalid_records(overrides):
    with pytest.raises(device_master.DeviceMasterError):
        device_master.parse_item("x", dynamo_item(**overrides))


def test_lookup_reads_configured_table_and_caches(monkeypatch):
    monkeypatch.setenv("DEVICE_MASTER_TABLE", "my-table")
    client = FakeDynamo(dynamo_item())
    assert device_master.lookup("xiao-e83dc1fb05fc", lambda: client) == MASTER
    assert device_master.lookup("xiao-e83dc1fb05fc", lambda: client) == MASTER
    assert client.calls == [{"TableName": "my-table", "Key": {"deviceId": {"S": "xiao-e83dc1fb05fc"}}}]


def test_lookup_default_table_name():
    client = FakeDynamo(dynamo_item())
    device_master.lookup("xiao-e83dc1fb05fc", lambda: client)
    assert client.calls[0]["TableName"] == "parking-status-device-master"


def test_lookup_unregistered_is_none_and_cached():
    client = FakeDynamo(None)
    assert device_master.lookup("nobody", lambda: client) is None
    assert device_master.lookup("nobody", lambda: client) is None
    assert len(client.calls) == 1


def test_lookup_refreshes_after_ttl(monkeypatch):
    clock = [1000.0]
    monkeypatch.setattr(device_master.time, "monotonic", lambda: clock[0])
    client = FakeDynamo(dynamo_item())
    device_master.lookup("xiao-e83dc1fb05fc", lambda: client)
    clock[0] += device_master.CACHE_TTL_SEC + 1
    device_master.lookup("xiao-e83dc1fb05fc", lambda: client)
    assert len(client.calls) == 2


def test_lookup_failure_without_cache_raises():
    client = FakeDynamo(error=RuntimeError("AccessDenied"))
    with pytest.raises(device_master.DeviceMasterError, match="AccessDenied"):
        device_master.lookup("xiao-e83dc1fb05fc", lambda: client)
    # 失敗はキャッシュしない（次の呼び出しでまた引く）
    with pytest.raises(device_master.DeviceMasterError):
        device_master.lookup("xiao-e83dc1fb05fc", lambda: client)
    assert len(client.calls) == 2


def test_lookup_failure_uses_stale_cache(monkeypatch, caplog):
    clock = [1000.0]
    monkeypatch.setattr(device_master.time, "monotonic", lambda: clock[0])
    device_master.lookup("xiao-e83dc1fb05fc", lambda: FakeDynamo(dynamo_item()))
    clock[0] += device_master.CACHE_TTL_SEC + 1
    assert device_master.lookup("xiao-e83dc1fb05fc", lambda: FakeDynamo(error=RuntimeError("timeout"))) == MASTER
    assert "stale cache" in caplog.text


# --- orion.upsert_entity ----------------------------------------------------


class FakeResponse:
    def __init__(self, status=204, body=b""):
        self.status = status
        self.body = body

    def read(self, size=-1):
        return self.body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def http_error(code, body=b"boom"):
    import io

    return urllib.error.HTTPError("https://orion.test/v2/entities", code, "err", {}, io.BytesIO(body))


class RoutedUrlopen:
    """Orion 宛ての HTTP（`__call__`）と、Cognito ログイン（`login`。`fetch_token` の代わり）を順序つきで記録する。"""

    def __init__(self, cognito=(), orion_results=()):
        self.cognito = list(cognito)  # トークン文字列か、上げる例外
        self.orion = list(orion_results)
        self.orion_requests = []
        self.order = []

    def login(self, credentials):
        self.order.append("cognito")
        result = self.cognito.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def __call__(self, request, timeout=None):
        self.order.append("orion")
        self.orion_requests.append((request, timeout))
        result = self.orion.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class FakeUrlopen:
    """呼び出しごとに results を順に返す（例外ならそれを上げる）。"""

    def __init__(self, *results):
        self.results = list(results)
        self.requests = []

    def __call__(self, request, timeout=None):
        self.requests.append((request, timeout))
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


CREDENTIALS = cognito_auth.CognitoCredentials(
    user_pool_id="ap-northeast-1_AbCdEf123", client_id="client123", username="bridge-user", password="p@ssw0rd"
)
FULL_CONFIG = orion.OrionConfig(url="https://orion.test", service="parking", service_path="/saga", auth=CREDENTIALS)
NO_AUTH_CONFIG = orion.OrionConfig(url="https://orion.test", service="parking", service_path="/saga")
LOGIN_OK = "id-tok"
LOGIN_FAILED = cognito_auth.AuthError("HTTP 400 NotAuthorizedException Incorrect username or password.")


def test_upsert_logs_in_and_sends_expected_request(monkeypatch):
    fake = RoutedUrlopen(cognito=[LOGIN_OK], orion_results=[FakeResponse(204)])
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", fake.login)

    assert orion.upsert_entity(EXPECTED_ENTITY, FULL_CONFIG) == 204

    assert fake.order == ["cognito", "orion"]  # ログインしてから送る
    request, timeout = fake.orion_requests[0]
    assert request.full_url == "https://orion.test/v2/entities?options=upsert"
    assert request.get_method() == "POST"
    assert timeout == orion.TIMEOUT_SEC
    assert json.loads(request.data.decode("utf-8")) == EXPECTED_ENTITY
    headers = {k.lower(): v for k, v in request.header_items()}
    assert headers["content-type"] == "application/json"
    assert headers["fiware-service"] == "parking"
    assert headers["fiware-servicepath"] == "/saga"
    assert headers["authorization"] == "Bearer id-tok"


def test_upsert_without_cognito_sends_no_authorization_and_does_not_log_in(monkeypatch):
    fake = FakeUrlopen(FakeResponse(201))
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", lambda *a, **k: pytest.fail("must not log in"))
    orion.upsert_entity(EXPECTED_ENTITY, orion.OrionConfig(url="https://orion.test"))
    headers = {k.lower() for k, _ in fake.requests[0][0].header_items()}
    assert headers == {"content-type"}


def test_upsert_retries_once_on_network_error(monkeypatch):
    fake = FakeUrlopen(urllib.error.URLError("connection reset"), FakeResponse(204))
    monkeypatch.setattr(orion, "_urlopen", fake)
    assert orion.upsert_entity(EXPECTED_ENTITY, NO_AUTH_CONFIG) == 204
    assert len(fake.requests) == 2


def test_upsert_retries_once_on_timeout_then_fails(monkeypatch):
    fake = FakeUrlopen(TimeoutError("timed out"), TimeoutError("timed out"))
    monkeypatch.setattr(orion, "_urlopen", fake)
    with pytest.raises(orion.OrionError, match="TimeoutError"):
        orion.upsert_entity(EXPECTED_ENTITY, NO_AUTH_CONFIG)
    assert len(fake.requests) == 2


def test_upsert_retries_on_5xx(monkeypatch):
    fake = FakeUrlopen(http_error(503), FakeResponse(204))
    monkeypatch.setattr(orion, "_urlopen", fake)
    assert orion.upsert_entity(EXPECTED_ENTITY, NO_AUTH_CONFIG) == 204


def test_upsert_does_not_retry_on_4xx(monkeypatch):
    fake = FakeUrlopen(http_error(400, b'{"error":"BadRequest"}'))
    monkeypatch.setattr(orion, "_urlopen", fake)
    with pytest.raises(orion.OrionError, match="HTTP 400.*BadRequest"):
        orion.upsert_entity(EXPECTED_ENTITY, NO_AUTH_CONFIG)
    assert len(fake.requests) == 1


def test_upsert_fetches_a_fresh_token_every_time(monkeypatch):
    """リフレッシュではなく、呼ぶたびにログインして取り直す。"""
    fake = RoutedUrlopen(cognito=[LOGIN_OK, LOGIN_OK], orion_results=[FakeResponse(204), FakeResponse(204)])
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", fake.login)
    orion.upsert_entity(EXPECTED_ENTITY, FULL_CONFIG)
    orion.upsert_entity(EXPECTED_ENTITY, FULL_CONFIG)
    assert fake.order == ["cognito", "orion", "cognito", "orion"]


def test_login_failure_does_not_reach_orion(monkeypatch):
    fake = RoutedUrlopen(cognito=[LOGIN_FAILED])
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", fake.login)
    with pytest.raises(orion.OrionError, match="cognito login failed.*NotAuthorizedException"):
        orion.upsert_entity(EXPECTED_ENTITY, FULL_CONFIG)
    assert fake.orion_requests == []


def test_orion_retry_reuses_the_token_without_logging_in_again(monkeypatch):
    fake = RoutedUrlopen(cognito=[LOGIN_OK], orion_results=[urllib.error.URLError("reset"), FakeResponse(204)])
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", fake.login)
    assert orion.upsert_entity(EXPECTED_ENTITY, FULL_CONFIG) == 204
    assert fake.order == ["cognito", "orion", "orion"]


def test_upsert_error_message_does_not_leak_secrets(monkeypatch):
    fake = RoutedUrlopen(cognito=[LOGIN_OK], orion_results=[http_error(401), http_error(401)])
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", fake.login)
    with pytest.raises(orion.OrionError) as excinfo:
        orion.upsert_entity(EXPECTED_ENTITY, FULL_CONFIG)
    assert "id-tok" not in str(excinfo.value) and "p@ssw0rd" not in str(excinfo.value)


COGNITO_ENV = {
    "ORION_URL": "https://orion.test/",
    "ORION_COGNITO_USER_POOL_ID": "ap-northeast-1_AbCdEf123",
    "ORION_COGNITO_CLIENT_ID": "client123",
    "ORION_COGNITO_USERNAME": "bridge-user",
    "ORION_COGNITO_PASSWORD": "p@ssw0rd",
}


def test_config_from_env():
    assert orion.OrionConfig.from_env({}) is None
    assert orion.OrionConfig.from_env({"ORION_URL": "  "}) is None
    assert orion.OrionConfig.from_env({"ORION_URL": "https://orion.test"}) == orion.OrionConfig(url="https://orion.test")
    config = orion.OrionConfig.from_env(
        {**COGNITO_ENV, "ORION_FIWARE_SERVICE": "parking", "ORION_FIWARE_SERVICEPATH": "/saga"}
    )
    assert config == orion.OrionConfig(
        url="https://orion.test",
        service="parking",
        service_path="/saga",
        auth=CREDENTIALS,
    )


def test_config_cognito_options():
    env = {**COGNITO_ENV, "ORION_COGNITO_CLIENT_SECRET": "sec", "ORION_COGNITO_TOKEN_TYPE": "access"}
    auth = orion.OrionConfig.from_env(env).auth
    assert (auth.region, auth.pool_name, auth.client_secret, auth.token_type) == ("ap-northeast-1", "AbCdEf123", "sec", "access")


@pytest.mark.parametrize(
    "missing",
    ["ORION_COGNITO_USER_POOL_ID", "ORION_COGNITO_CLIENT_ID", "ORION_COGNITO_USERNAME", "ORION_COGNITO_PASSWORD"],
)
def test_config_rejects_incomplete_cognito_settings(missing):
    env = {k: v for k, v in COGNITO_ENV.items() if k != missing}
    with pytest.raises(orion.OrionError, match=missing):
        orion.OrionConfig.from_env(env)


@pytest.mark.parametrize("pool_id", ["AbCdEf123", "ap-northeast-1", "ap-northeast-1_", "ap_northeast_1_x"])
def test_config_rejects_malformed_user_pool_id(pool_id):
    with pytest.raises(orion.OrionError, match="USER_POOL_ID"):
        orion.OrionConfig.from_env({**COGNITO_ENV, "ORION_COGNITO_USER_POOL_ID": pool_id})


def test_config_rejects_unknown_token_type():
    with pytest.raises(orion.OrionError, match="TOKEN_TYPE"):
        orion.OrionConfig.from_env({**COGNITO_ENV, "ORION_COGNITO_TOKEN_TYPE": "refresh"})


def test_credentials_repr_hides_secrets():
    text = repr(cognito_auth.CognitoCredentials("ap-northeast-1_x", "c", "u", "hunter2", client_secret="s3cr3t"))
    assert "hunter2" not in text and "s3cr3t" not in text


# --- ハンドラへの組み込み ----------------------------------------------------


@pytest.fixture
def orion_env(monkeypatch):
    monkeypatch.setenv("ORION_URL", "https://orion.test")
    monkeypatch.setenv("ORION_FIWARE_SERVICE", "parking")


@pytest.fixture
def registered(monkeypatch):
    client = FakeDynamo(dynamo_item())
    monkeypatch.setattr(device_master, "_client", lambda: client)
    return client


@pytest.fixture
def orion_ok(monkeypatch):
    fake = FakeUrlopen(*[FakeResponse(204)] * 5)
    monkeypatch.setattr(orion, "_urlopen", fake)
    return fake


def orion_body(fake, index=0):
    return json.loads(fake.requests[index][0].data.decode("utf-8"))


def test_disabled_without_orion_url(monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(device_master, "_client", lambda: pytest.fail("must not read the device master"))
    result = handler.handler(LTE_EVENT, None)
    assert json.loads(result["body"])["orion"] == "disabled"
    assert len(telemetry_lines(caplog)) == 1


def test_lte_event_is_upserted(orion_env, registered, orion_ok, caplog):
    caplog.set_level(logging.INFO)
    result = handler.handler(LTE_EVENT, None)

    assert json.loads(result["body"]) == {"ok": True, "deviceId": "xiao-e83dc1fb05fc", "status": "full", "orion": "upserted"}
    assert orion_body(orion_ok) == EXPECTED_ENTITY
    messages = [r.getMessage() for r in caplog.records]
    # ログが先、Orion が後
    assert messages[0].startswith("parking-status telemetry received: ")
    assert any(m.startswith("orion upsert ok: urn:ngsi:ParkingStatusSensor:xiao-e83dc1fb05fc") for m in messages[1:])


def test_legacy_available_is_written_as_open(orion_env, registered, orion_ok):
    handler.handler({**LTE_EVENT, "status": "available"}, None)
    assert orion_body(orion_ok)["status"]["value"] == "open"


def test_telemetry_line_keeps_all_fields(orion_env, registered, orion_ok, caplog):
    """Orion に送らない診断項目も、CloudWatch のログ行には全部残る。"""
    caplog.set_level(logging.INFO)
    event = {**LTE_EVENT, "sync": {"prevOutcome": "confirmed"}, "pot": {"enabled": False, "adcRaw": 0}}
    handler.handler(event, None)
    line = telemetry_lines(caplog)[0]
    assert json.loads(line.split(": ", 1)[1]) == event
    assert "sync" not in orion_body(orion_ok) and "pot" not in orion_body(orion_ok)


def test_unregistered_device_is_skipped(orion_env, monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(device_master, "_client", lambda: FakeDynamo(None))
    fake = FakeUrlopen()
    monkeypatch.setattr(orion, "_urlopen", fake)

    result = handler.handler(LTE_EVENT, None)

    assert json.loads(result["body"])["orion"] == "skipped"
    assert fake.requests == []
    assert "orion skipped: xiao-e83dc1fb05fc is not registered" in caplog.text
    assert len(telemetry_lines(caplog)) == 1


def test_disabled_device_is_skipped(orion_env, monkeypatch):
    monkeypatch.setattr(device_master, "_client", lambda: FakeDynamo(dynamo_item(enabled={"BOOL": False})))
    fake = FakeUrlopen()
    monkeypatch.setattr(orion, "_urlopen", fake)
    assert json.loads(handler.handler(LTE_EVENT, None)["body"])["orion"] == "skipped"
    assert fake.requests == []


def test_device_master_failure_skips_orion_but_keeps_log(orion_env, monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(device_master, "_client", lambda: FakeDynamo(error=RuntimeError("AccessDenied")))
    fake = FakeUrlopen()
    monkeypatch.setattr(orion, "_urlopen", fake)

    result = handler.handler(LTE_EVENT, None)

    assert result["statusCode"] == 200 and json.loads(result["body"])["orion"] == "skipped"
    assert fake.requests == []
    assert "orion skipped: device master lookup failed" in caplog.text
    assert len(telemetry_lines(caplog)) == 1


@pytest.mark.parametrize("event", [{}, {"deviceId": "xiao-e83dc1fb05fc"}], ids=["empty", "no-status"])
def test_event_without_device_id_or_status_is_skipped(orion_env, registered, orion_ok, event):
    result = handler.handler(event, None)
    assert json.loads(result["body"])["orion"] == "skipped"
    assert orion_ok.requests == []


def test_orion_failure_does_not_raise_and_logs_once(orion_env, registered, monkeypatch, caplog):
    """Orion が落ちていても例外にしない（例外だと IoT ルールが再実行して、ログ行が二重になる）。"""
    caplog.set_level(logging.INFO)
    fake = FakeUrlopen(urllib.error.URLError("down"), urllib.error.URLError("down"))
    monkeypatch.setattr(orion, "_urlopen", fake)

    result = handler.handler(LTE_EVENT, None)

    assert result["statusCode"] == 200 and json.loads(result["body"])["orion"] == "failed"
    assert len(fake.requests) == 2  # 即時リトライ 1 回
    assert "orion upsert failed: URLError" in caplog.text
    assert len(telemetry_lines(caplog)) == 1
    assert [r.getMessage() for r in caplog.records][0].startswith("parking-status telemetry received")


def test_unexpected_error_in_orion_path_does_not_raise(orion_env, registered, monkeypatch, caplog):
    monkeypatch.setattr(ngsi, "build_entity", lambda *a, **k: 1 / 0)
    result = handler.handler(LTE_EVENT, None)
    assert json.loads(result["body"])["orion"] == "failed"
    assert "orion upsert failed: unexpected error" in caplog.text


def test_lorawan_uplink_is_upserted(orion_env, monkeypatch, orion_ok, caplog):
    caplog.set_level(logging.INFO)
    monkeypatch.setattr(lorawan, "_client", lambda: FakeIotWireless(name="xiao-e83dc1fb05fc"))
    monkeypatch.setattr(device_master, "_client", lambda: FakeDynamo(dynamo_item()))

    result = handler.handler(make_message(VECTORS[0]["hex"]), None)

    assert json.loads(result["body"])["orion"] == "upserted"
    entity = orion_body(orion_ok)
    assert entity["id"] == "urn:ngsi:ParkingStatusSensor:xiao-e83dc1fb05fc"
    assert entity["status"]["value"] == "open"
    assert entity["dateObserved"]["value"] == "2026-10-01T07:47:49Z"
    assert set(entity) == set(EXPECTED_ENTITY)  # LoRaWAN の診断項目（network / lorawan / sync / power）は入らない
    assert len(telemetry_lines(caplog)) == 1


def test_rejected_lorawan_uplink_is_not_sent_to_orion(orion_env, monkeypatch, orion_ok):
    monkeypatch.setattr(lorawan, "_client", lambda: FakeIotWireless(missing=True))
    monkeypatch.setattr(device_master, "_client", lambda: pytest.fail("must not read the device master"))
    result = handler.handler(make_message(VECTORS[0]["hex"]), None)
    assert json.loads(result["body"])["ok"] is False
    assert orion_ok.requests == []


# --- ハンドラ × Cognito ------------------------------------------------------


@pytest.fixture
def cognito_env(orion_env, monkeypatch):
    for name, value in COGNITO_ENV.items():
        if name != "ORION_URL":
            monkeypatch.setenv(name, value)


def route(monkeypatch, **kwargs):
    fake = RoutedUrlopen(**kwargs)
    monkeypatch.setattr(orion, "_urlopen", fake)
    monkeypatch.setattr(cognito_auth, "fetch_token", fake.login)
    return fake


def test_handler_logs_in_per_invocation_and_sends_bearer_token(cognito_env, registered, monkeypatch):
    fake = route(monkeypatch, cognito=[LOGIN_OK, LOGIN_OK], orion_results=[FakeResponse(204), FakeResponse(204)])
    handler.handler(LTE_EVENT, None)
    result = handler.handler(LTE_EVENT, None)
    assert json.loads(result["body"])["orion"] == "upserted"
    assert fake.order == ["cognito", "orion", "cognito", "orion"]
    headers = {k.lower(): v for k, v in fake.orion_requests[0][0].header_items()}
    assert headers["authorization"] == "Bearer id-tok"


def test_handler_login_failure_does_not_raise_and_keeps_log(cognito_env, registered, monkeypatch, caplog):
    caplog.set_level(logging.INFO)
    fake = route(monkeypatch, cognito=[LOGIN_FAILED])

    result = handler.handler(LTE_EVENT, None)

    assert result["statusCode"] == 200 and json.loads(result["body"])["orion"] == "failed"
    assert fake.orion_requests == []
    assert "orion upsert failed: cognito login failed: HTTP 400 NotAuthorizedException" in caplog.text
    assert "p@ssw0rd" not in caplog.text
    assert len(telemetry_lines(caplog)) == 1


def test_handler_does_not_log_in_for_skipped_devices(cognito_env, monkeypatch):
    monkeypatch.setattr(device_master, "_client", lambda: FakeDynamo(None))
    fake = route(monkeypatch)
    assert json.loads(handler.handler(LTE_EVENT, None)["body"])["orion"] == "skipped"
    assert fake.order == []


def test_handler_incomplete_cognito_settings_fail_without_raising(orion_env, registered, monkeypatch, caplog):
    monkeypatch.setenv("ORION_COGNITO_USERNAME", "bridge-user")  # client id と password が無い
    fake = route(monkeypatch)
    result = handler.handler(LTE_EVENT, None)
    assert json.loads(result["body"])["orion"] == "failed"
    assert "incomplete Cognito settings" in caplog.text
    assert fake.order == []
