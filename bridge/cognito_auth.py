"""Orion 用のトークンを Cognito User Pool から取得する（#7）。

トークンには有効期限があるため、リフレッシュはせず、**Orion に送るたびに**ユーザー名とパスワードで
ログインして取り直す。ログインは SRP（`USER_SRP_AUTH`。パスワードそのものは送らない）で、
`InitiateAuth` → `RespondToAuthChallenge(PASSWORD_VERIFIER)` の 2 往復。どちらも認証前に呼ぶ API で、
AWS の署名も IAM 権限も要らない。標準ライブラリだけで書く（SRP の計算も含む）。

前提（Orion 側の Cognito の設定。管理者に確認する）:
- App Client で `ALLOW_USER_SRP_AUTH` が有効
- 専用ユーザーが確認済み（`FORCE_CHANGE_PASSWORD` のままだとログインできない）。MFA は無効
- クライアントシークレットがある App Client なら `client_secret` も要る（`SECRET_HASH` を付ける）

パスワードとトークンは、ログ・例外メッセージ・`repr` に出さない。
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone

TIMEOUT_SEC = 5
ATTEMPTS = 2  # 1 回目 + 即時リトライ 1 回（ネットワーク障害・タイムアウト・5xx のみ）
TOKEN_TYPES = {"id": "IdToken", "access": "AccessToken"}

# SRP-6a のグループ（RFC 3526 の 3072 ビット MODP グループ。Cognito 共通）。g = 2。
N_HEX = (
    "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD"
    "EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED"
    "EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
    "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B"
    "E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF6955817183995497CEA956AE515D2261898FA0510"
    "15728E5A8AAAC42DAD33170D04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
    "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D87602733EC86A64521F2B18177B200C"
    "BBE117577A615D6C770988C0BAD946E208E24FA074E5AB3143DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF"
)
G_HEX = "2"
N = int(N_HEX, 16)
G = int(G_HEX, 16)
INFO_BITS = b"Caldera Derived Key"

_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

_urlopen = urllib.request.urlopen  # テストで差し替える
_utcnow = lambda: datetime.now(timezone.utc)  # noqa: E731 — テストで差し替える


class AuthError(Exception):
    pass


@dataclass(frozen=True)
class CognitoCredentials:
    user_pool_id: str  # `ap-northeast-1_xxxxxxxxx`（先頭がリージョン、後ろがプール名として SRP に使われる）
    client_id: str
    username: str
    password: str = field(repr=False)
    client_secret: str | None = field(default=None, repr=False)
    token_type: str = "id"  # Orion が受け取るトークン: `id`（IdToken）または `access`（AccessToken）

    @property
    def region(self) -> str:
        return self.user_pool_id.split("_", 1)[0]

    @property
    def pool_name(self) -> str:
        return self.user_pool_id.split("_", 1)[1]


# --- SRP の計算 -------------------------------------------------------------


def _sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().zfill(64)


def _hex_hash(hex_string: str) -> str:
    return _sha256_hex(bytes.fromhex(hex_string))


def _pad_hex(value: int | str) -> str:
    """符号付き整数として読まれないよう、先頭が 8 以上なら `00` を足し、桁数を偶数にそろえる。"""
    text = value if isinstance(value, str) else f"{value:x}"
    if len(text) % 2 == 1:
        return "0" + text
    if text[0] in "89abcdefABCDEF":
        return "00" + text
    return text


K = int(_hex_hash("00" + N_HEX + "0" + G_HEX), 16)


def _random_small_a() -> int:
    """クライアントの秘密値 a（0 以外）。テストで差し替える。"""
    while True:
        a = int.from_bytes(os.urandom(128), "big") % N
        if a:
            return a


def _timestamp(now: datetime) -> str:
    """`Tue Oct 6 04:53:54 UTC 2026`（Cognito の指定する書式。日は 0 埋めなし、英語の曜日・月名）。"""
    return f"{_DAYS[now.weekday()]} {_MONTHS[now.month - 1]} {now.day} {now:%H:%M:%S} UTC {now.year}"


def _secret_hash(credentials: CognitoCredentials, username: str) -> str:
    digest = hmac.new(
        credentials.client_secret.encode("utf-8"),
        (username + credentials.client_id).encode("utf-8"),
        hashlib.sha256,
    ).digest()
    return base64.b64encode(digest).decode("ascii")


def password_authentication_key(
    pool_name: str, user_id: str, password: str, small_a: int, server_b: int, salt_hex: str
) -> bytes:
    """SRP の共有鍵から、署名用の 16 バイトの鍵を導く。"""
    large_a = pow(G, small_a, N)
    if server_b % N == 0:
        raise AuthError("SRP: invalid server value B")
    u = int(_hex_hash(_pad_hex(large_a) + _pad_hex(server_b)), 16)
    if u == 0:
        raise AuthError("SRP: invalid scrambling value")
    x = int(_hex_hash(_pad_hex(salt_hex) + _sha256_hex(f"{pool_name}{user_id}:{password}".encode("utf-8"))), 16)
    s = pow((server_b - K * pow(G, x, N)) % N, small_a + u * x, N)
    prk = hmac.new(bytes.fromhex(_pad_hex(u)), bytes.fromhex(_pad_hex(s)), hashlib.sha256).digest()
    return hmac.new(prk, INFO_BITS + b"\x01", hashlib.sha256).digest()[:16]


# --- API 呼び出し -----------------------------------------------------------


def _describe_http_error(exc: urllib.error.HTTPError) -> str:
    """`NotAuthorizedException: Incorrect username or password.` のような形にする（応答にパスワードは入らない）。"""
    try:
        body = json.loads(exc.read(2000))
        error_type = str(body.get("__type", "")).split("#")[-1]
        message = str(body.get("message", ""))[:200]
    except Exception:  # noqa: BLE001
        error_type, message = "", ""
    return f"HTTP {exc.code} {error_type} {message}".strip()


def _call(credentials: CognitoCredentials, operation: str, body: dict) -> dict:
    """Cognito の API を 1 回呼ぶ。認証エラー（4xx）は再試行しない。ネットワーク障害・5xx は即時リトライ 1 回。"""
    request = urllib.request.Request(
        f"https://cognito-idp.{credentials.region}.amazonaws.com/",
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/x-amz-json-1.1",
            "X-Amz-Target": f"AWSCognitoIdentityProviderService.{operation}",
        },
        method="POST",
    )
    last_error: AuthError | None = None
    for _ in range(ATTEMPTS):
        try:
            with _urlopen(request, timeout=TIMEOUT_SEC) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as exc:  # URLError より先に捕まえる（HTTPError は URLError の子）
            error = AuthError(_describe_http_error(exc))
            if exc.code < 500:
                raise error from exc
            last_error = error
        except (urllib.error.URLError, OSError) as exc:  # タイムアウト（TimeoutError）も OSError
            last_error = AuthError(f"{type(exc).__name__}: {exc}")
    assert last_error is not None
    raise last_error


def fetch_token(credentials: CognitoCredentials) -> str:
    """SRP でログインしてトークンを 1 つ返す。失敗は AuthError。"""
    small_a = _random_small_a()
    large_a = pow(G, small_a, N)
    auth_parameters = {"USERNAME": credentials.username, "SRP_A": f"{large_a:x}"}
    if credentials.client_secret:
        auth_parameters["SECRET_HASH"] = _secret_hash(credentials, credentials.username)

    challenge = _call(
        credentials,
        "InitiateAuth",
        {"AuthFlow": "USER_SRP_AUTH", "ClientId": credentials.client_id, "AuthParameters": auth_parameters},
    )
    if challenge.get("ChallengeName") != "PASSWORD_VERIFIER":
        raise AuthError(f"unexpected response to InitiateAuth (ChallengeName={challenge.get('ChallengeName')})")
    params = challenge.get("ChallengeParameters") or {}
    try:
        user_id = params["USER_ID_FOR_SRP"]
        salt_hex = params["SALT"]
        server_b = int(params["SRP_B"], 16)
        secret_block = params["SECRET_BLOCK"]
        secret_block_bytes = base64.b64decode(secret_block)
    except (KeyError, ValueError) as exc:
        raise AuthError(f"malformed SRP challenge: {type(exc).__name__}") from exc

    key = password_authentication_key(credentials.pool_name, user_id, credentials.password, small_a, server_b, salt_hex)
    timestamp = _timestamp(_utcnow())
    message = credentials.pool_name.encode("utf-8") + user_id.encode("utf-8") + secret_block_bytes + timestamp.encode("utf-8")
    responses = {
        "TIMESTAMP": timestamp,
        "USERNAME": user_id,
        "PASSWORD_CLAIM_SECRET_BLOCK": secret_block,
        "PASSWORD_CLAIM_SIGNATURE": base64.b64encode(hmac.new(key, message, hashlib.sha256).digest()).decode("ascii"),
    }
    if credentials.client_secret:
        responses["SECRET_HASH"] = _secret_hash(credentials, user_id)

    result = _call(
        credentials,
        "RespondToAuthChallenge",
        {"ChallengeName": "PASSWORD_VERIFIER", "ClientId": credentials.client_id, "ChallengeResponses": responses},
    )
    if result.get("ChallengeName"):
        raise AuthError(f"unsupported challenge {result['ChallengeName']} (use a confirmed user without MFA)")
    token = (result.get("AuthenticationResult") or {}).get(TOKEN_TYPES[credentials.token_type])
    if not token:
        raise AuthError(f"{TOKEN_TYPES[credentials.token_type]} is missing in the response")
    return token
