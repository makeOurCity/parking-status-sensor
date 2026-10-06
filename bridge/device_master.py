"""デバイスマスター（#7, #14）: `deviceId` → エンティティの `name` / `location`。

保管先は DynamoDB（テーブル名は環境変数 `DEVICE_MASTER_TABLE`、既定 `parking-status-device-master`。
`deviceId`（文字列）がパーティションキー）。Lambda は読み取り（GetItem）だけで、編集は
`infra/device-master.sh` かコンソールで行う。

- 結果は `CACHE_TTL_SEC` の間、コンテナ内でキャッシュする（未登録もキャッシュする）
- 取得に失敗したら古いキャッシュを使い、キャッシュも無ければ `DeviceMasterError`
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass
from typing import Any, Callable

logger = logging.getLogger()

DEFAULT_TABLE = "parking-status-device-master"
CACHE_TTL_SEC = 300


class DeviceMasterError(Exception):
    """マスターを引けなかった、または登録内容が不正。"""


@dataclass(frozen=True)
class DeviceMaster:
    device_id: str
    name: str
    lat: float
    lon: float
    enabled: bool = True


_cache: dict[str, tuple[float, DeviceMaster | None]] = {}
_dynamodb_client = None


def _client():
    global _dynamodb_client
    if _dynamodb_client is None:
        import boto3  # Lambda ランタイムに入っている。テストでは使わない。
        from botocore.config import Config

        # 遅い・詰まったときに Lambda 全体を巻き込まないよう、待ちを短くする。
        _dynamodb_client = boto3.client(
            "dynamodb",
            config=Config(connect_timeout=2, read_timeout=3, retries={"max_attempts": 2}),
        )
    return _dynamodb_client


def parse_item(device_id: str, item: dict) -> DeviceMaster:
    """DynamoDB の項目（低レベル API の型付き形式）を DeviceMaster にする。不正なら DeviceMasterError。"""
    try:
        name = item["name"]["S"].strip()
        lat = float(item["lat"]["N"])
        lon = float(item["lon"]["N"])
        enabled = bool(item["enabled"]["BOOL"]) if "enabled" in item else True
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise DeviceMasterError(f"invalid device master record for {device_id}: {exc!r}") from exc
    if not name:
        raise DeviceMasterError(f"invalid device master record for {device_id}: name is empty")
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise DeviceMasterError(f"invalid device master record for {device_id}: lat/lon out of range ({lat}, {lon})")
    return DeviceMaster(device_id=device_id, name=name, lat=lat, lon=lon, enabled=enabled)


def lookup(device_id: str, client_factory: Callable[[], Any] | None = None) -> DeviceMaster | None:
    """`deviceId` のマスターを返す。未登録なら None。取得できなければ DeviceMasterError。"""
    now = time.monotonic()
    cached = _cache.get(device_id)
    if cached and now - cached[0] < CACHE_TTL_SEC:
        return cached[1]

    table = os.environ.get("DEVICE_MASTER_TABLE", DEFAULT_TABLE)
    try:
        response = (client_factory or _client)().get_item(TableName=table, Key={"deviceId": {"S": device_id}})
    except Exception as exc:  # noqa: BLE001 — 権限不足・タイムアウトなどすべて同じ扱い
        if cached:
            logger.warning("device master lookup failed, using stale cache: %s", exc)
            return cached[1]
        raise DeviceMasterError(f"device master lookup failed: {exc}") from exc

    item = response.get("Item")
    master = parse_item(device_id, item) if item else None
    _cache[device_id] = (now, master)
    return master


def clear_cache() -> None:
    """テスト用。"""
    _cache.clear()
