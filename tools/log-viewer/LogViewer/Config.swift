import Foundation

/// Cognito/CloudWatch connection info for the parking-status PoC (`parking-private` AWS
/// account). These identifiers alone grant nothing — signing in still requires the
/// developer's Cognito password, and the vended IAM role only allows reading
/// `logGroupName` below. See docs/ios-app-cognito.md in the repo for the full design.
enum AWSConfig {
    static let region = "ap-northeast-1"
    static let cognitoUserPoolId = "ap-northeast-1_qa1vrH2IU"
    static let cognitoAppClientId = "p0fl67p8k9u56k38dqn7gj5k9"
    static let cognitoIdentityPoolId = "ap-northeast-1:1d149d81-f0fd-43d1-93f6-f948514604ff"
    static let logGroupName = "/aws/lambda/parking-status-bridge"

    /// Pre-filled username hint on the sign-in screen (single-user PoC tool).
    static let loginUsernameHint = "kazuki@code4japan.org"

    /// Heartbeat is a forced send every 1 hour; add a buffer to avoid false
    /// "offline" flags from normal network/publish jitter.
    static let offlineThreshold: TimeInterval = 90 * 60

    /// How often the dashboard/device detail screens re-query CloudWatch Logs
    /// on their own while in the foreground, so manual pull-to-refresh is
    /// rarely needed.
    static let autoRefreshInterval: TimeInterval = 30

    /// BGTaskScheduler identifier for background refresh (must match the
    /// `BGTaskSchedulerPermittedIdentifiers` entry in project.yml/Info.plist).
    static let backgroundRefreshTaskIdentifier = "org.code4japan.parkingsensor.logviewer.refresh"

    /// Earliest the OS may run the next background refresh. This is a
    /// request, not a guarantee — iOS schedules BGAppRefreshTask
    /// opportunistically based on usage patterns and battery, so actual
    /// gaps can run from minutes to several hours.
    static let backgroundRefreshMinimumInterval: TimeInterval = 15 * 60
}
