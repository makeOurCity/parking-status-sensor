import Foundation

/// タイムラインに出すデバイスを決める（#132）。
///
/// - 対象: デバイスマスターの全 ID ∪ ダッシュボードが持つ機体（直近 3 日に受信があった機体）のうち、
///   取得した期間に受信が 1 件以上あるもの。
/// - ダッシュボードの一覧だけを使うと、4 日以上止まった機体が消えてしまい、
///   「データなしの帯で送信停止に気づく」目的に反する。マスターを足して無送信機を残す。
/// - 疎通確認の試験 ID（`xiao-test-device` など）は、ログには出るがマスターには無い。
///   ダッシュボードの一覧から外れる 3 日後には消える。
/// - 期間内に 1 件も受信が無い機体は出せない（設置前と区別できない）。
enum TimelineDeviceSelector {
    /// deviceId の昇順（名前の変更で列が入れ替わらない）。
    static func select(
        masterIds: Set<String>,
        activeIds: [String],
        eventDeviceIds: Set<String>
    ) -> [String] {
        masterIds.union(activeIds)
            .intersection(eventDeviceIds)
            .sorted()
    }
}
