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
| `rawSensor.red` | Number | TCS34725 赤チャンネル生値 |
| `rawSensor.green` | Number | TCS34725 緑チャンネル生値 |
| `rawSensor.blue` | Number | TCS34725 青チャンネル生値 |
| `rawSensor.clear` | Number | TCS34725 クリアチャンネル（輝度）生値 |
| `determinedBy` | Text | 判定主体: `device` または `server` |
| `threshold` | Number | 判定に使用した R-G 差の閾値 |
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
