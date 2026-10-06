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
| `name` | Text | 利用者に見せる名称（駐車場名＋表示面）。例: 「佐賀市役所第1駐車場」 |
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

`name` と `location` は運用側で登録した値。登録のない端末のエンティティは作られない。登録内容を変更した場合、Orion に反映されるのはその端末の次の更新後（下記「更新のタイミング」）。

### status 値の定義

| 値 | 日本語ラベル | 意味 |
|---|---|---|
| `full` | 満 | 満車（赤が支配的: R - G ≥ threshold） |
| `open` | 空 | 空車（緑が支配的: G - R ≥ threshold） |
| `unknown` | 不明 | 消灯・遷移中など判定不能（差が threshold 未満） |

`full` / `open` は FIWARE Smart Data Models の `OffStreetParking.status` の値と同じ。

### 更新のタイミング

エンティティは、端末からの送信のたびに upsert（なければ作成、あれば更新）される。

- 端末は **約 5 分ごと**に色を読み取り、`status` を判定する
- `status` が前回から**変わったときは、その周期のうちに更新**される
- **変化がなくても、約 1 時間ごとに強制的に更新**される（定期送信）。このとき `dateObserved` が進むので、端末が動いていることの確認になる
- `status` が変わらない限り、`rawSensor` の値だけが変動しても更新されない
- 通信に失敗した場合は、次回以降の周期で再送される（反映が遅れることがある）
- 更新のたびに、全属性が更新時点の値で書き込まれる

利用側の目安: `status` が変わらない間も約 1 時間ごとに `dateObserved` が進む。**90 分以上更新がなければ、端末の停止や通信不良の可能性がある**。

### エンティティ例

```json
{
  "id": "urn:ngsi:ParkingStatusSensor:xiao-e83dc1fb05fc",
  "type": "ParkingStatusSensor",
  "name": { "type": "Text", "value": "佐賀市役所第1駐車場" },
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
    "value": { "type": "Point", "coordinates": [130.3008, 33.2629] }
  },
  "dateObserved": { "type": "DateTime", "value": "2026-06-17T12:00:00Z" }
}
```
