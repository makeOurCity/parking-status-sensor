"""全テスト共通: Orion の環境変数と、デバイス名・デバイスマスターのキャッシュを毎回まっさらにする。"""

import pytest

import device_master
import lorawan


@pytest.fixture(autouse=True)
def clean_orion_environment(monkeypatch):
    for name in (
        "ORION_URL",
        "ORION_FIWARE_SERVICE",
        "ORION_FIWARE_SERVICEPATH",
        "ORION_COGNITO_USER_POOL_ID",
        "ORION_COGNITO_CLIENT_ID",
        "ORION_COGNITO_USERNAME",
        "ORION_COGNITO_PASSWORD",
        "ORION_COGNITO_CLIENT_SECRET",
        "ORION_COGNITO_TOKEN_TYPE",
        "DEVICE_MASTER_TABLE",
    ):
        monkeypatch.delenv(name, raising=False)
    device_master.clear_cache()
    lorawan.clear_device_cache()
    yield
    device_master.clear_cache()
    lorawan.clear_device_cache()
