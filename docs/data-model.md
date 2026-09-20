# データモデル設計

## 設計方針

- エンティティタイプ: `ParkingStatusSensor`（NGSIv2）
- 粒度: **センサ1台 = エンティティ1件**。満空灯1面が判定対象1つに対応する
- 集約なし: 1階・2階など表示対象が異なる場合は別エンティティとして独立させる
- PoC段階は `ParkingStatusSensor` 単体で完結させ、`OffStreetParking`（FIWARE Smart Data Models）へのマッピングは将来フェーズで対応する

## エンティティ: ParkingStatusSensor

### フィールド一覧

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | String | `urn:ngsi:ParkingStatusSensor:<識別子>` |
| `type` | String | `ParkingStatusSensor` |
| `status` | Text | 満空判定結果。値は下表参照 |
| `status.metadata.label` | Text | ステータスの日本語ラベル |
| `rawSensor.red` | Number | カラーセンサ赤チャンネル生値（VEML6040 R） |
| `rawSensor.green` | Number | カラーセンサ緑チャンネル生値（VEML6040 G） |
| `rawSensor.blue` | Number | カラーセンサ青チャンネル生値（VEML6040 B） |
| `rawSensor.clear` | Number | 輝度相当の生値（VEML6040 White。MQTT ペイロードの `raw.clear` に対応） |
| `determinedBy` | Text | 判定主体: `device` または `server` |
| `threshold` | Number | 判定に使用した R-G 差の閾値（#60: ポテンショメーター搭載機体では現地調整による実効値） |
| `deviceId` | Text | ESP32 デバイス識別子 |
| `location` | geo:json | センサ設置箇所の緯度経度（GeoJSON Point） |
| `dateObserved` | DateTime | 観測日時（ISO 8601） |

### status 値の定義

| 値 | 日本語ラベル | 意味 |
|---|---|---|
| `full` | 満 | 満車（赤が支配的: R - G ≥ threshold） |
| `available` | 空 | 空車（緑が支配的: G - R ≥ threshold） |
| `unknown` | 不明 | 消灯・遷移中など判定不能（差が threshold 未満） |

### エンティティ例

```json
{
  "id": "urn:ngsi:ParkingStatusSensor:sendai-001",
  "type": "ParkingStatusSensor",
  "status": {
    "type": "Text",
    "value": "available",
    "metadata": {
      "label": { "type": "Text", "value": "空" }
    }
  },
  "rawSensor": {
    "type": "StructuredValue",
    "value": {
      "red": 150,
      "green": 820,
      "blue": 200,
      "clear": 1200
    }
  },
  "determinedBy": { "type": "Text", "value": "device" },
  "threshold":    { "type": "Number", "value": 100 },
  "deviceId":     { "type": "Text", "value": "xiao-esp32s3-001" },
  "location": {
    "type": "geo:json",
    "value": { "type": "Point", "coordinates": [140.869, 38.268] }
  },
  "dateObserved": { "type": "DateTime", "value": "2026-06-17T12:00:00Z" }
}
```

## 将来対応: OffStreetParking へのマッピング

FIWARE Smart Data Models の [`OffStreetParking`](https://github.com/smart-data-models/dataModel.Parking/tree/master/OffStreetParking) は駐車場の標準エンティティ。PoC 完了後にブリッジ層へ変換ロジックを追加し、`ParkingStatusSensor` の `status` を `OffStreetParking` の属性へマッピングする。

| ParkingStatusSensor.status | OffStreetParking.status | 備考 |
|---|---|---|
| `full` | `full` | 満車 |
| `available` | `open` | 空車（台数は不明のため availableSpotNumber は設定しない） |
| `unknown` | — | マッピングしない |

`ParkingStatusSensor` と `OffStreetParking` は `refParkingLot` Relationship で紐付ける予定。

## MQTT ペイロードの診断フィールド（`sync.*` / `network.*` / `bootMode.*`）

ファームは満空状態のほかに、送信サイクルの診断情報を MQTT ペイロードに含める（[sync-delivery-design.md](sync-delivery-design.md)）。

- `network.*`（`transport`、接続時間、`publishAttempts` 等）と `sync.*`（`prevOutcome`、`pending`、`lastConfirmedStatus` 等）は **端末の運用診断専用**
- `bootMode.*`（`active`・`slot`・`totalSlots`。#50「電源投入直後のブートモード」）も同様に **端末の運用診断専用**。電源投入(コールドブート)直後の無条件連続送信中かどうか、その何回目の送信かを示す。通常サイクルでは常に `active=false`・`slot=0`・`totalSlots=0`（詳細: [50-boot-mode-design.md](50-boot-mode-design.md)）
- `pot.*`（`enabled`・`adcRaw`。#60「現地調整用ポテンショメーター」）も同様に **端末の運用診断専用**。`enabled` はポット機能のビルド時有効/無効、`adcRaw` は平均済みの生ADC値（0〜4095）。ポット無効機体では常に `enabled=false`・`adcRaw=0` で、`threshold` は従来通りの固定値のまま（詳細: [60-potentiometer-threshold-design.md](60-potentiometer-threshold-design.md)）
- これらは **Orion（NGSIv2）エンティティにはマップしない**。bridge（#7）の変換対象外
- 送達確認は `network.deliveryConfirmed`（廃止済み）ではなく、**次サイクルの `sync.prevOutcome == confirmed`** と `sync.lastConfirmedBootCount` で判断する
