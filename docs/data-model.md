# データモデル設計

## 設計方針

- エンティティタイプ: `ParkingStatusSensor`（NGSIv2）
- 粒度: **センサ1台 = エンティティ1件**。満空灯1面が判定対象1つに対応する
- 集約なし: 1階・2階など表示対象が異なる場合は別エンティティとして独立させる
- PoC段階は `ParkingStatusSensor` 単体で完結させる
- 駐車場の名前と設置位置は `name` / `location` に入っている。利用側は端末（`deviceId`）を意識せず、これらを読めばよい

## エンティティ: ParkingStatusSensor

### フィールド一覧

| フィールド | 型 | 説明 |
|---|---|---|
| `id` | String | `urn:ngsi:ParkingStatusSensor:<deviceId>` |
| `type` | String | `ParkingStatusSensor` |
| `name` | Text | 利用者に見せる名称（駐車場名＋表示面）。例: 「サンプル駐車場 1階」 |
| `status` | Text | 満空判定結果。値は下表参照 |
| `status.metadata.label` | Text | ステータスの日本語ラベル |
| `rawSensor.red` | Number | カラーセンサ赤チャンネル生値（VEML6040 R） |
| `rawSensor.green` | Number | カラーセンサ緑チャンネル生値（VEML6040 G） |
| `rawSensor.blue` | Number | カラーセンサ青チャンネル生値（VEML6040 B） |
| `rawSensor.clear` | Number | 輝度相当の生値（VEML6040 White。MQTT ペイロードの `raw.clear` に対応） |
| `determinedBy` | Text | 判定主体: `device` または `server` |
| `threshold` | Number | 判定に使用した R-G 差の閾値（#60: ポテンショメーター搭載機体では現地調整による実効値） |
| `deviceId` | Text | ESP32 デバイス識別子 |
| `location` | geo:json | センサ設置箇所の緯度経度（GeoJSON Point。座標は `[経度, 緯度]` の順） |
| `dateObserved` | DateTime | 観測日時（ISO 8601） |

`name` と `location` は運用側で登録した値。登録のない端末のエンティティは作られない。登録内容を変更した場合、Orion に反映されるのはその端末の次の送信後（状態変化、または 1 時間ごとのハートビート）。

### status 値の定義

| 値 | 日本語ラベル | 意味 |
|---|---|---|
| `full` | 満 | 満車（赤が支配的: R - G ≥ threshold） |
| `open` | 空 | 空車（緑が支配的: G - R ≥ threshold） |
| `unknown` | 不明 | 消灯・遷移中など判定不能（差が threshold 未満） |

`full` / `open` は FIWARE Smart Data Models の `OffStreetParking.status` の値と同じ。

### エンティティ例

```json
{
  "id": "urn:ngsi:ParkingStatusSensor:xiao-e83dc1fb05fc",
  "type": "ParkingStatusSensor",
  "name": { "type": "Text", "value": "サンプル駐車場 1階" },
  "status": {
    "type": "Text",
    "value": "open",
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
  "deviceId":     { "type": "Text", "value": "xiao-e83dc1fb05fc" },
  "location": {
    "type": "geo:json",
    "value": { "type": "Point", "coordinates": [140.869, 38.268] }
  },
  "dateObserved": { "type": "DateTime", "value": "2026-06-17T12:00:00Z" }
}
```
