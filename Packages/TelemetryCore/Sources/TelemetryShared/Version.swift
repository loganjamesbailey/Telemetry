/// Version constants shared across app, helper, and widget.
public enum TelemetryVersion {
    /// Bumped on ANY change to the XPC protocol shape or semantics.
    public static let protocolVersion = 1
    /// Bumped on any helper code change; the app bounces the daemon via
    /// unregister()/register() when the handshake reports a mismatch.
    public static let helperVersion = "0.1.0"
}
