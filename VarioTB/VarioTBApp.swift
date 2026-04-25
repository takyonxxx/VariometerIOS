import SwiftUI
import AVFoundation

@main
struct VarioTBApp: App {
    init() {
        // Configure audio session for background + Bluetooth routing
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback,
                                    mode: .default,
                                    options: [.mixWithOthers, .allowBluetooth, .allowBluetoothA2DP, .allowAirPlay])
            try session.setActive(true)
        } catch {
            print("AudioSession error: \(error)")
        }
        // Keep screen on while flying
        UIApplication.shared.isIdleTimerDisabled = true
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .statusBarHidden(true)
                .onOpenURL { url in
                    // Deep link entry point. iOS Camera, Safari and any
                    // sharer-side app can hand us a URL via:
                    //
                    //   xctsk:<base64-or-raw-task-payload>
                    //   xctsk://<…>
                    //   variotb://task?data=<payload>
                    //
                    // Two-path delivery so cold launches work too:
                    //   - Post a notification (warm launches: observers
                    //     already attached, pick it up immediately)
                    //   - Stash in DeepLink.pendingPayload (cold
                    //     launches: ContentView drains this in .onAppear
                    //     once it mounts)
                    if let payload = DeepLink.extractTaskPayload(from: url) {
                        DeepLink.pendingPayload = payload
                        NotificationCenter.default.post(
                            name: DeepLink.taskImportNotification,
                            object: nil,
                            userInfo: ["payload": payload])
                    }
                }
        }
    }
}

/// Namespaces our deep-link helpers. See Info.plist CFBundleURLTypes.
enum DeepLink {
    /// Posted when the app is opened via a URL that carries a task
    /// payload. userInfo["payload"] is the raw task string (e.g.
    /// "XCTSK:..." or an already-extracted base64 body).
    static let taskImportNotification = Notification.Name("DeepLinkTaskImport")

    /// Fallback storage: if the app is being cold-launched from a URL,
    /// the notification may fire before any view is ready to listen.
    /// We stash the payload here so ContentView can pick it up once
    /// it appears. Cleared after consumption.
    static var pendingPayload: String?

    /// Pull the task body out of an incoming URL. Handles the three
    /// common shapes we expect:
    ///
    ///   1. xctsk:<body>           → whole URL minus the scheme
    ///   2. xctsk://<host+path>    → re-assemble into a plain string
    ///   3. variotb://task?data=…  → "data" query parameter
    ///
    /// XCTrack historically encodes the task as `xctsk:<base64>` (no
    /// slashes) because the payload is a plain text token. iOS's
    /// `URL.host/path` split doesn't apply — the scheme body is the
    /// whole thing. We also accept the slash-form that some
    /// implementations emit.
    static func extractTaskPayload(from url: URL) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        let absolute = url.absoluteString
        print("[DeepLink] scheme=\(scheme)")
        print("[DeepLink] absoluteString length=\(absolute.count)")
        print("[DeepLink] first 100: \(String(absolute.prefix(100)))")

        // variotb://task?data=…  — our own scheme. Hand the entire URL
        // to TaskQRCodec.decodeTask which knows how to unwrap it.
        if scheme == "variotb" {
            return absolute
        }

        // xctsk:<body>  or  xctsk://<body>  — XCTrack / Flyskyhy
        // compatible. Re-attach the "XCTSK:" prefix so downstream
        // decoding is uniform regardless of exact URL shape.
        //
        // Critical detail: when iOS Camera taps a QR whose payload is
        // `xctsk:{"g":...}` (Flyskyhy-style plain text starting with
        // the xctsk: prefix), it parses the whole thing as a URL.
        // JSON syntax characters (`{` `"` `,` etc.) get percent-encoded
        // along the way — `absoluteString` returns e.g. `xctsk:%7B%22g%22...`.
        // We must percent-decode the body before handing it to the
        // JSON decoder, otherwise the decoder sees garbage and fails.
        if scheme == "xctsk" {
            let prefixLen = "xctsk:".count
            guard absolute.count > prefixLen else { return nil }
            var body = String(absolute.dropFirst(prefixLen))
            if body.hasPrefix("//") { body = String(body.dropFirst(2)) }
            // Reverse percent-encoding so `{`, `"`, `,`, etc. survive.
            // If decoding fails (rare — only for malformed input),
            // fall back to the raw body so we still try to parse.
            let decoded = body.removingPercentEncoding ?? body
            print("[DeepLink] xctsk body after decode (first 100): \(String(decoded.prefix(100)))")
            return "XCTSK:" + decoded
        }

        return nil
    }
}
