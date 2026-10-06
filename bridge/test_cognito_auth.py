"""Cognito からのトークン取得（SRP。cognito_auth.py）のテスト。

Cognito には接続せず、サーバー側の SRP 計算まで再現した `FakeCognito` を相手にする
（実際の Cognito での成功は、使い捨ての User Pool で別途確認済み）。
"""

import base64
import hashlib
import hmac
import json
import urllib.error
from datetime import datetime, timezone

import pytest

import cognito_auth
from cognito_auth import G, K, N, _hex_hash, _pad_hex, _sha256_hex
from test_orion import FakeResponse, http_error

POOL_ID = "ap-northeast-1_AbCdEf123"
POOL_NAME = "AbCdEf123"
CLIENT_ID = "client123"
USERNAME = "bridge-user"
PASSWORD = "p@ssw0rd"
CREDENTIALS = cognito_auth.CognitoCredentials(user_pool_id=POOL_ID, client_id=CLIENT_ID, username=USERNAME, password=PASSWORD)


def cognito_error(error_type, message, code=400):
    return http_error(code, json.dumps({"__type": error_type, "message": message}).encode())


class FakeCognito:
    """`urlopen` の代わり。SRP のサーバー側（検証子 v・B の生成・署名の検証）を実装している。"""

    def __init__(self, client_secret=None, challenge_after=None):
        self.client_secret = client_secret
        self.challenge_after = challenge_after  # RespondToAuthChallenge の応答に返すチャレンジ名
        self.salt_hex = "0a1b2c3d4e5f60718293a4b5c6d7e8f9"
        x = int(_hex_hash(_pad_hex(self.salt_hex) + _sha256_hex(f"{POOL_NAME}{USERNAME}:{PASSWORD}".encode())), 16)
        self.v = pow(G, x, N)
        self.b = int.from_bytes(hashlib.sha256(b"server-secret").digest() * 8, "big") % N
        self.big_b = (K * self.v + pow(G, self.b, N)) % N
        self.secret_block = base64.b64encode(b"opaque-secret-block").decode()
        self.requests = []  # (operation, body)
        self.faults = []  # 先頭から順に、呼び出しごとに上げる例外（None なら通常処理）
        self.large_a = None

    def __call__(self, request, timeout=None):
        operation = request.get_header("X-amz-target").rsplit(".", 1)[1]
        body = json.loads(request.data)
        self.requests.append((operation, body))
        fault = self.faults.pop(0) if self.faults else None
        if fault:
            raise fault
        if body["ClientId"] != CLIENT_ID:
            raise cognito_error("ResourceNotFoundException", "client not found")
        return getattr(self, operation)(body)

    def _secret_hash(self, username):
        digest = hmac.new(self.client_secret.encode(), (username + CLIENT_ID).encode(), hashlib.sha256).digest()
        return base64.b64encode(digest).decode()

    def InitiateAuth(self, body):  # noqa: N802
        assert body["AuthFlow"] == "USER_SRP_AUTH"
        params = body["AuthParameters"]
        if self.client_secret and params.get("SECRET_HASH") != self._secret_hash(params["USERNAME"]):
            raise cognito_error("NotAuthorizedException", "SECRET_HASH was not received")
        if params["USERNAME"] != USERNAME:
            raise cognito_error("UserNotFoundException", "User does not exist.")
        self.large_a = int(params["SRP_A"], 16)
        return FakeResponse(
            200,
            json.dumps(
                {
                    "ChallengeName": "PASSWORD_VERIFIER",
                    "ChallengeParameters": {
                        "USER_ID_FOR_SRP": USERNAME,
                        "SALT": self.salt_hex,
                        "SRP_B": f"{self.big_b:x}",
                        "SECRET_BLOCK": self.secret_block,
                    },
                }
            ).encode(),
        )

    def RespondToAuthChallenge(self, body):  # noqa: N802
        assert body["ChallengeName"] == "PASSWORD_VERIFIER"
        r = body["ChallengeResponses"]
        if self.client_secret and r.get("SECRET_HASH") != self._secret_hash(r["USERNAME"]):
            raise cognito_error("NotAuthorizedException", "SECRET_HASH was not received")
        u = int(_hex_hash(_pad_hex(self.large_a) + _pad_hex(self.big_b)), 16)
        s = pow(self.large_a * pow(self.v, u, N) % N, self.b, N)
        prk = hmac.new(bytes.fromhex(_pad_hex(u)), bytes.fromhex(_pad_hex(s)), hashlib.sha256).digest()
        key = hmac.new(prk, b"Caldera Derived Key\x01", hashlib.sha256).digest()[:16]
        message = POOL_NAME.encode() + USERNAME.encode() + base64.b64decode(r["PASSWORD_CLAIM_SECRET_BLOCK"]) + r["TIMESTAMP"].encode()
        expected = base64.b64encode(hmac.new(key, message, hashlib.sha256).digest()).decode()
        if r["PASSWORD_CLAIM_SIGNATURE"] != expected:
            raise cognito_error("NotAuthorizedException", "Incorrect username or password.")
        if self.challenge_after:
            return FakeResponse(200, json.dumps({"ChallengeName": self.challenge_after}).encode())
        return FakeResponse(200, json.dumps({"AuthenticationResult": {"IdToken": "id-tok", "AccessToken": "acc-tok"}}).encode())

    def operations(self):
        return [operation for operation, _ in self.requests]


@pytest.fixture
def cognito(monkeypatch):
    def install(**kwargs):
        fake = FakeCognito(**kwargs)
        monkeypatch.setattr(cognito_auth, "_urlopen", fake)
        return fake

    return install


# --- 定数・書式 -------------------------------------------------------------


def test_srp_constants():
    assert N.bit_length() == 3072 and G == 2
    # k = H(N | g)。AWS の SDK で使われている値（Cognito 共通）
    assert f"{K:x}" == "538282c4354742d7cbbde2359fcf67f9f5b3a6b08791e5011b43b8a5b66d9ee6"


@pytest.mark.parametrize(
    "when, expected",
    [
        (datetime(2026, 10, 6, 4, 53, 54, tzinfo=timezone.utc), "Tue Oct 6 04:53:54 UTC 2026"),
        (datetime(2026, 1, 17, 23, 5, 9, tzinfo=timezone.utc), "Sat Jan 17 23:05:09 UTC 2026"),
        (datetime(2026, 12, 6, 0, 0, 0, tzinfo=timezone.utc), "Sun Dec 6 00:00:00 UTC 2026"),
    ],
)
def test_timestamp_format(when, expected):
    assert cognito_auth._timestamp(when) == expected


def test_pad_hex():
    assert _pad_hex(0xABC) == "0abc"  # 桁数を偶数に
    assert _pad_hex(0x80) == "0080"  # 先頭が 8 以上なら 00 を足す
    assert _pad_hex(0x7F) == "7f"


def test_region_and_pool_name_come_from_pool_id():
    credentials = cognito_auth.CognitoCredentials("us-east-1_Pool99", "c", "u", "p")
    assert (credentials.region, credentials.pool_name) == ("us-east-1", "Pool99")


# --- ログイン ---------------------------------------------------------------


def test_logs_in_with_srp_and_returns_id_token(cognito):
    fake = cognito()
    assert cognito_auth.fetch_token(CREDENTIALS) == "id-tok"
    assert fake.operations() == ["InitiateAuth", "RespondToAuthChallenge"]


def test_access_token_type(cognito):
    cognito()
    credentials = cognito_auth.CognitoCredentials(POOL_ID, CLIENT_ID, USERNAME, PASSWORD, token_type="access")
    assert cognito_auth.fetch_token(credentials) == "acc-tok"


def test_request_shape_and_password_is_never_sent(cognito):
    fake = cognito()
    cognito_auth.fetch_token(CREDENTIALS)

    first = fake.requests[0][1]
    assert first["AuthFlow"] == "USER_SRP_AUTH" and first["ClientId"] == CLIENT_ID
    assert set(first["AuthParameters"]) == {"USERNAME", "SRP_A"}
    assert first["AuthParameters"]["USERNAME"] == USERNAME
    assert all(PASSWORD not in json.dumps(body) for _, body in fake.requests)


def test_requests_go_to_the_pool_region(monkeypatch):
    urls = []

    def fake(request, timeout=None):
        urls.append(request.full_url)
        raise cognito_error("NotAuthorizedException", "x")

    monkeypatch.setattr(cognito_auth, "_urlopen", fake)
    with pytest.raises(cognito_auth.AuthError):
        cognito_auth.fetch_token(cognito_auth.CognitoCredentials("us-east-1_Pool99", "c", "u", "p"))
    assert urls == ["https://cognito-idp.us-east-1.amazonaws.com/"]


def test_client_secret_adds_secret_hash_to_both_calls(cognito):
    fake = cognito(client_secret="shh")
    credentials = cognito_auth.CognitoCredentials(POOL_ID, CLIENT_ID, USERNAME, PASSWORD, client_secret="shh")
    assert cognito_auth.fetch_token(credentials) == "id-tok"
    assert "SECRET_HASH" in fake.requests[0][1]["AuthParameters"]
    assert "SECRET_HASH" in fake.requests[1][1]["ChallengeResponses"]


def test_missing_client_secret_fails(cognito):
    cognito(client_secret="shh")
    with pytest.raises(cognito_auth.AuthError, match="NotAuthorizedException"):
        cognito_auth.fetch_token(CREDENTIALS)


def test_each_login_uses_a_fresh_random_a(cognito):
    fake = cognito()
    cognito_auth.fetch_token(CREDENTIALS)
    cognito_auth.fetch_token(CREDENTIALS)
    assert fake.requests[0][1]["AuthParameters"]["SRP_A"] != fake.requests[2][1]["AuthParameters"]["SRP_A"]


# --- 失敗 -------------------------------------------------------------------


def test_wrong_password(cognito):
    fake = cognito()
    credentials = cognito_auth.CognitoCredentials(POOL_ID, CLIENT_ID, USERNAME, "wrong-password")
    with pytest.raises(cognito_auth.AuthError) as excinfo:
        cognito_auth.fetch_token(credentials)
    assert str(excinfo.value) == "HTTP 400 NotAuthorizedException Incorrect username or password."
    assert "wrong-password" not in str(excinfo.value)
    assert fake.operations() == ["InitiateAuth", "RespondToAuthChallenge"]  # 認証エラーは再試行しない


def test_unknown_user(cognito):
    fake = cognito()
    credentials = cognito_auth.CognitoCredentials(POOL_ID, CLIENT_ID, "nobody", PASSWORD)
    with pytest.raises(cognito_auth.AuthError, match="UserNotFoundException"):
        cognito_auth.fetch_token(credentials)
    assert fake.operations() == ["InitiateAuth"]


def test_retries_each_call_once_on_network_error(cognito):
    fake = cognito()
    fake.faults = [urllib.error.URLError("reset"), None, TimeoutError("timed out"), None]
    assert cognito_auth.fetch_token(CREDENTIALS) == "id-tok"
    assert fake.operations() == ["InitiateAuth"] * 2 + ["RespondToAuthChallenge"] * 2


def test_retries_on_5xx_then_fails(cognito):
    fake = cognito()
    fake.faults = [cognito_error("InternalErrorException", "boom", 500), cognito_error("InternalErrorException", "boom", 503)]
    with pytest.raises(cognito_auth.AuthError, match="HTTP 503"):
        cognito_auth.fetch_token(CREDENTIALS)
    assert fake.operations() == ["InitiateAuth", "InitiateAuth"]


def test_timeout_fails(cognito):
    fake = cognito()
    fake.faults = [TimeoutError("timed out"), TimeoutError("timed out")]
    with pytest.raises(cognito_auth.AuthError, match="TimeoutError"):
        cognito_auth.fetch_token(CREDENTIALS)


def test_new_password_challenge_is_unsupported(cognito):
    cognito(challenge_after="NEW_PASSWORD_REQUIRED")
    with pytest.raises(cognito_auth.AuthError, match="NEW_PASSWORD_REQUIRED"):
        cognito_auth.fetch_token(CREDENTIALS)


def test_unexpected_initial_challenge(monkeypatch):
    monkeypatch.setattr(
        cognito_auth, "_urlopen", lambda request, timeout=None: FakeResponse(200, b'{"ChallengeName":"SMS_MFA"}')
    )
    with pytest.raises(cognito_auth.AuthError, match="SMS_MFA"):
        cognito_auth.fetch_token(CREDENTIALS)


def test_malformed_challenge(monkeypatch):
    body = json.dumps({"ChallengeName": "PASSWORD_VERIFIER", "ChallengeParameters": {"SALT": "00"}}).encode()
    monkeypatch.setattr(cognito_auth, "_urlopen", lambda request, timeout=None: FakeResponse(200, body))
    with pytest.raises(cognito_auth.AuthError, match="malformed"):
        cognito_auth.fetch_token(CREDENTIALS)


def test_missing_token_in_response(cognito, monkeypatch):
    fake = cognito()
    original = fake.RespondToAuthChallenge
    monkeypatch.setattr(fake, "RespondToAuthChallenge", lambda body: (original(body), FakeResponse(200, b'{"AuthenticationResult":{}}'))[1])
    with pytest.raises(cognito_auth.AuthError, match="IdToken"):
        cognito_auth.fetch_token(CREDENTIALS)
