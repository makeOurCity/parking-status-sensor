"""FIWARE Orion への NGSIv2 upsert（#7）。標準ライブラリ（urllib）だけで書く。

接続先は Lambda の環境変数で渡す。
- `ORION_URL`（必須。未設定なら Orion には送らない）例: `https://orion.example.org`
- `ORION_FIWARE_SERVICE` / `ORION_FIWARE_SERVICEPATH`（あれば `Fiware-Service` / `Fiware-ServicePath` ヘッダに付ける）
- Cognito のログイン情報（あれば、**送るたびに**ログインしてトークンを取り直し、`Authorization: Bearer <token>` に付ける。`cognito_auth.py`）
  - `ORION_COGNITO_USER_POOL_ID` / `ORION_COGNITO_CLIENT_ID` / `ORION_COGNITO_USERNAME` / `ORION_COGNITO_PASSWORD`（4 つそろえる。一部だけだと設定ミスとして失敗にする。リージョンは User Pool ID の先頭から決まる）
  - `ORION_COGNITO_CLIENT_SECRET`（シークレット付き App Client のとき）
  - `ORION_COGNITO_TOKEN_TYPE`（`id` または `access`。既定 `id`。Orion が受け取る方を管理者に確認する）
  - どれも無ければ認証ヘッダなしで送る

失敗時は `OrionError` を上げる。呼び出し側（handler.py）が捕まえて、例外にせずログだけ残す。
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Mapping

import cognito_auth

TIMEOUT_SEC = 5
ATTEMPTS = 2  # 1 回目 + 即時リトライ 1 回（ネットワーク障害・タイムアウト・5xx のみ）

_urlopen = urllib.request.urlopen  # テストで差し替える


class OrionError(Exception):
    pass


@dataclass(frozen=True)
class OrionConfig:
    url: str
    service: str | None = None
    service_path: str | None = None
    auth: cognito_auth.CognitoCredentials | None = None

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "OrionConfig | None":
        """環境変数から設定を作る。`ORION_URL` が無ければ None。Cognito の設定が不完全なら OrionError。"""
        env = os.environ if env is None else env
        url = (env.get("ORION_URL") or "").strip().rstrip("/")
        if not url:
            return None
        return cls(
            url=url,
            service=env.get("ORION_FIWARE_SERVICE") or None,
            service_path=env.get("ORION_FIWARE_SERVICEPATH") or None,
            auth=_cognito_from_env(env),
        )


def _cognito_from_env(env: Mapping[str, str]) -> cognito_auth.CognitoCredentials | None:
    required = (
        "ORION_COGNITO_USER_POOL_ID",
        "ORION_COGNITO_CLIENT_ID",
        "ORION_COGNITO_USERNAME",
        "ORION_COGNITO_PASSWORD",
    )
    optional = ("ORION_COGNITO_CLIENT_SECRET", "ORION_COGNITO_TOKEN_TYPE")
    if not any(env.get(name) for name in required + optional):
        return None
    missing = [name for name in required if not env.get(name)]
    if missing:
        raise OrionError(f"incomplete Cognito settings, missing: {', '.join(missing)}")
    token_type = env.get("ORION_COGNITO_TOKEN_TYPE") or "id"
    if token_type not in cognito_auth.TOKEN_TYPES:
        raise OrionError(f"ORION_COGNITO_TOKEN_TYPE must be one of {sorted(cognito_auth.TOKEN_TYPES)}")
    user_pool_id = env["ORION_COGNITO_USER_POOL_ID"]
    if not re.fullmatch(r"[a-z]{2}(-[a-z]+)+-\d_[A-Za-z0-9]+", user_pool_id):
        raise OrionError("ORION_COGNITO_USER_POOL_ID must look like ap-northeast-1_xxxxxxxxx")
    return cognito_auth.CognitoCredentials(
        user_pool_id=user_pool_id,
        client_id=env["ORION_COGNITO_CLIENT_ID"],
        username=env["ORION_COGNITO_USERNAME"],
        password=env["ORION_COGNITO_PASSWORD"],
        client_secret=env.get("ORION_COGNITO_CLIENT_SECRET") or None,
        token_type=token_type,
    )


def _read_detail(exc: urllib.error.HTTPError) -> str:
    try:
        return exc.read(300).decode("utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        return ""


def upsert_entity(entity: dict, config: OrionConfig) -> int:
    """`POST /v2/entities?options=upsert`。成功したら HTTP ステータスを返す。失敗は OrionError。

    Cognito の設定があれば、呼ぶたびにログインしてトークンを取る（ログインに失敗したら Orion には送らない）。
    4xx はリクエスト自体の問題なので再試行しない。パスワード・トークンはログ・例外メッセージに出さない。
    """
    token = None
    if config.auth:
        try:
            token = cognito_auth.fetch_token(config.auth)
        except cognito_auth.AuthError as exc:
            raise OrionError(f"cognito login failed: {exc}") from exc

    headers = {"Content-Type": "application/json"}
    if config.service:
        headers["Fiware-Service"] = config.service
    if config.service_path:
        headers["Fiware-ServicePath"] = config.service_path
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(
        f"{config.url}/v2/entities?options=upsert",
        data=json.dumps(entity, ensure_ascii=False).encode("utf-8"),
        headers=headers,
        method="POST",
    )

    last_error: OrionError | None = None
    for _ in range(ATTEMPTS):
        try:
            with _urlopen(request, timeout=TIMEOUT_SEC) as response:
                return response.status
        except urllib.error.HTTPError as exc:  # URLError より先に捕まえる（HTTPError は URLError の子）
            error = OrionError(f"HTTP {exc.code} {_read_detail(exc)}".strip())
            if exc.code < 500:
                raise error from exc
            last_error = error
        except (urllib.error.URLError, OSError) as exc:  # タイムアウト（TimeoutError）も OSError
            last_error = OrionError(f"{type(exc).__name__}: {exc}")
    assert last_error is not None
    raise last_error
