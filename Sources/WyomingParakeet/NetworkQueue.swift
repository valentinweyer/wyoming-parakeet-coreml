import Foundation

/// Dedicated queue for all NWListener/NWConnection callbacks.
///
/// Deliberately NOT `.main`: `DispatchQueue.main` is backed by the main
/// thread's run loop, which only gets serviced by an active run loop pump
/// (`RunLoop.main.run()`, `dispatchMain()`, or a UI framework's event loop).
/// This process is a headless `@main static func main() async` that parks
/// on `Task.sleep` in a loop rather than running a traditional run loop, so
/// `.main`-queued Network.framework callbacks fired inconsistently — the
/// first one or two would go through (apparently from residual startup
/// scheduling) and then silently stop, which looked like a hung connection
/// with no error. A queue backed by Dispatch's own thread pool doesn't need
/// a run loop to be serviced and delivers reliably regardless.
let networkQueue = DispatchQueue(label: "wyoming.network")
