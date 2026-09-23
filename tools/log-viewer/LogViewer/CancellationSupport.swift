import Foundation

/// `.refreshable` / `.task` both hand their closures a Task that SwiftUI
/// cancels whenever a newer load supersedes it (pull-to-refresh firing again,
/// the view disappearing, navigating back, ...). That cancellation surfaces
/// as `CancellationError` or `URLError(.cancelled)` from `URLSession` — it
/// isn't a real failure, so view models should swallow it instead of showing
/// it as an error message.
func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}
