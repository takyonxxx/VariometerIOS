import Foundation
import CoreLocation
import Combine

/// LiveTrack24 live tracking client using the official Native Session-Aware
/// HTTP API: https://www.livetrack24.com/wiki/LiveTracking%20API
///
/// Protocol:
///   1. LOGIN:  GET /client.php?op=login&user=X&pass=Y  → returns userID (integer)
///              Returns "0" on bad credentials.
///   2. SESSION ID: 32-bit integer built as:
///              top bit = 1,
///              next 7 bits random,
///              lower 24 bits = userID
///   3. START:  GET /track.php?leolive=2&sid=SID&pid=1&client=VarioTB&v=1.0
///                             &user=X&pass=Y&phone=iPhone&gps=Internal%20GPS
///                             &trk1=5&vtype=1&vname=Wing+Model
///   4. FIX:    GET /track.php?leolive=4&sid=SID&pid=N
///                             &lat=LAT&lon=LON&alt=ALT&sog=SOG&cog=COG&tm=UNIX
///   5. END:    GET /track.php?leolive=3&sid=SID&pid=N&prid=0
///              prid = 0 (Everything OK), 1 (Need retrieve), 2-4 (need help)
///
/// Vtype codes used:
///   1  = Paraglider
///   2  = Flex wing / hang glider FAI1
///   4  = Rigid wing FAI5
///   8  = Glider (sailplane)
///  16  = Paramotor
final class LiveTrack24Tracker: ObservableObject {
    static weak var shared: LiveTrack24Tracker?

    @Published var isActive: Bool = false
    @Published var lastUploadAt: Date?
    @Published var lastUploadStatus: String = ""
    @Published var totalFixesSent: Int = 0
    @Published var sessionID: UInt32? = nil

    // Prefer HTTPS; if the server rejects (DNS, 4xx on /client.php), try HTTP.
    // Info.plist has an ATS exception for livetrack24.com so HTTP is allowed.
    private var baseURL = "https://www.livetrack24.com"
    private var triedHttpFallback = false
    private var packetID: Int = 1
    private var uploadTimer: Timer?
    private let uploadInterval: TimeInterval = 5.0    // bulk-send every 5s
    private var pendingFixes: [Fix] = []
    private let lock = NSLock()

    private struct Fix {
        let lat: Double
        let lon: Double
        let alt: Double
        let sogKmh: Double
        let cogDeg: Double
        let tm: TimeInterval
    }

    weak var settings: AppSettings?
    weak var locationMgr: LocationManager?

    func attach(settings: AppSettings, locationManager: LocationManager) {
        self.settings = settings
        self.locationMgr = locationManager
        LiveTrack24Tracker.shared = self
    }

    // MARK: - Public lifecycle

    func start() {
        guard !isActive else { return }
        guard let s = settings,
              !s.liveTrackUsername.isEmpty else {
            lastUploadStatus = "Kullanıcı adı eksik"
            return
        }
        guard let password = KeychainStore.get("xcontestPassword"),
              !password.isEmpty else {
            lastUploadStatus = "Şifre eksik"
            return
        }

        lastUploadStatus = "Giriş yapılıyor…"
        triedHttpFallback = false
        attemptLogin(user: s.liveTrackUsername, pass: password, settings: s)
    }

    /// Try login; if it fails and we haven't tried HTTP yet, retry over HTTP.
    private func attemptLogin(user: String, pass: String, settings s: AppSettings) {
        login(user: user, pass: pass) { [weak self] userID in
            guard let self = self else { return }
            if let uid = userID, uid > 0 {
                let sid = self.makeSessionID(userID: uid)
                DispatchQueue.main.async {
                    self.sessionID = sid
                    self.packetID = 1
                    self.sendStart(user: user, pass: pass, sid: sid, settings: s)
                }
                return
            }
            // HTTPS didn't work — try HTTP once
            if !self.triedHttpFallback && self.baseURL.hasPrefix("https://") {
                self.triedHttpFallback = true
                self.baseURL = "http://www.livetrack24.com"
                self.attemptLogin(user: user, pass: pass, settings: s)
            }
            // else: leave the detailed error message already set by login()
        }
    }

    func stop() {
        guard isActive else {
            lastUploadStatus = "Durduruldu"
            uploadTimer?.invalidate()
            uploadTimer = nil
            return
        }
        // Send end packet (status = 0 "Everything OK")
        sendEnd(status: 0)
        uploadTimer?.invalidate()
        uploadTimer = nil
        isActive = false
        lastUploadStatus = "Durduruldu"
        pendingFixes.removeAll()
        sessionID = nil
    }

    /// Call from the main tick (~1 Hz is ideal; we de-duplicate by timestamp).
    func recordFix() {
        guard isActive, let lm = locationMgr, lm.hasFix, let c = lm.coordinate else { return }
        // COG (Course Over Ground) MUST be the GPS-derived ground track,
        // not the magnetic compass heading. LiveTrack24 expects the
        // direction the pilot is *moving*, which is what every tracking
        // protocol means by "course". Using the compass-backed
        // courseDeg here would have sent the phone's pointing direction
        // — wrong while gliding through wind drift, and meaningless
        // when the phone is strapped sideways in a harness.
        //
        // gpsCourseDeg is -1 until the pilot starts moving fast enough
        // for the GPS track vector to be meaningful. In that case we
        // send 0, which servers tolerate as "course unknown" — the
        // alternative (skipping the fix) would lose the lat/lon/alt
        // data the tracking page does need.
        let cog = lm.gpsCourseDeg >= 0 ? lm.gpsCourseDeg : 0
        let fix = Fix(lat: c.latitude, lon: c.longitude,
                      alt: lm.fusedAltitude,
                      sogKmh: lm.groundSpeedKmh,
                      cogDeg: cog,
                      tm: Date().timeIntervalSince1970)
        lock.lock()
        pendingFixes.append(fix)
        // Cap the buffer so a flaky connection doesn't grow memory forever
        if pendingFixes.count > 500 {
            pendingFixes.removeFirst(pendingFixes.count - 500)
        }
        lock.unlock()
    }

    // MARK: - Login

    /// Strictly percent-encode a value for use in a query string. We don't
    /// use URLQueryItem alone because iOS's default allowed character set
    /// leaves `+` un-encoded, and some PHP servers (including livetrack24.com)
    /// interpret `+` as a space. This causes valid passwords containing `+`
    /// to fail authentication. We restrict the allowed set to unreserved
    /// chars so `+`, `&`, `=`, `@`, `#` etc. are all percent-encoded.
    private func queryEncode(_ s: String) -> String {
        // RFC 3986 unreserved: ALPHA / DIGIT / - . _ ~
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func login(user: String, pass: String, completion: @escaping (UInt32?) -> Void) {
        let urlString = "\(baseURL)/client.php?op=login&user=\(queryEncode(user))&pass=\(queryEncode(pass))"
        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async { self.lastUploadStatus = "URL oluşturulamadı" }
            completion(nil); return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("VarioTB/1.0 iOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, response, err in
            if let err = err {
                DispatchQueue.main.async {
                    self.lastUploadStatus = "Ağ hatası: \(err.localizedDescription)"
                }
                completion(nil); return
            }
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            let bodyRaw = (data.flatMap { String(data: $0, encoding: .utf8) }) ?? ""
            let body = bodyRaw.trimmingCharacters(in: .whitespacesAndNewlines)

            guard (200..<400).contains(code) else {
                DispatchQueue.main.async { self.lastUploadStatus = "HTTP \(code)" }
                completion(nil); return
            }

            if body == "0" {
                DispatchQueue.main.async {
                    self.lastUploadStatus = "Kullanıcı adı/şifre hatalı"
                }
                completion(nil); return
            }

            // Extract userID from response — first run of digits
            let digits = body.unicodeScalars.prefix { CharacterSet.decimalDigits.contains($0) }
            let numericString = String(String.UnicodeScalarView(digits))
            if let uid = UInt32(numericString), uid > 0 {
                completion(uid)
                return
            }

            DispatchQueue.main.async {
                if body.isEmpty {
                    self.lastUploadStatus = "Boş yanıt (HTTP \(code))"
                } else {
                    let snippet = String(body.prefix(80))
                    self.lastUploadStatus = "Yanıt: \"\(snippet)\""
                }
            }
            completion(nil)
        }.resume()
    }

    // MARK: - Session ID

    /// Build a session ID per LiveTrack24 spec:
    ///   bit 31 = 1
    ///   bits 30-24 = random 7 bits
    ///   bits 23-0  = userID (lower 24 bits)
    private func makeSessionID(userID: UInt32) -> UInt32 {
        let rnd = UInt32.random(in: 0...UInt32.max)
        return (rnd & 0x7F000000) | (userID & 0x00FFFFFF) | 0x80000000
    }

    // MARK: - Start / Fix / End

    private func sendStart(user: String, pass: String,
                           sid: UInt32, settings: AppSettings) {
        var comps = URLComponents(string: "\(baseURL)/track.php")!
        let vtype = liveTrack24VehicleType(for: settings.gliderType)
        let vname = buildGliderName(settings)
        comps.queryItems = [
            URLQueryItem(name: "leolive", value: "2"),
            URLQueryItem(name: "sid", value: "\(sid)"),
            URLQueryItem(name: "pid", value: "\(packetID)"),
            URLQueryItem(name: "client", value: "VarioTB"),
            URLQueryItem(name: "v", value: "1.0"),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "pass", value: pass),
            URLQueryItem(name: "phone", value: "iPhone"),
            URLQueryItem(name: "gps", value: "Internal GPS"),
            URLQueryItem(name: "trk1", value: "5"),            // 5 s between fixes
            URLQueryItem(name: "vtype", value: "\(vtype)"),
            URLQueryItem(name: "vname", value: vname)
        ]
        guard let url = comps.url else { return }
        packetID += 1

        URLSession.shared.dataTask(with: URLRequest(url: url)) { [weak self] _, response, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let err = err {
                    self.lastUploadStatus = "Hata: \(err.localizedDescription)"
                    return
                }
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    self.isActive = true
                    self.lastUploadStatus = ""
                    self.startUploadTimer()
                } else if let http = response as? HTTPURLResponse {
                    self.lastUploadStatus = "Sunucu \(http.statusCode)"
                }
            }
        }.resume()
    }

    private func sendEnd(status: Int) {
        guard let sid = sessionID,
              let user = settings?.liveTrackUsername,
              let pass = KeychainStore.get("xcontestPassword") else { return }
        var comps = URLComponents(string: "\(baseURL)/track.php")!
        comps.queryItems = [
            URLQueryItem(name: "leolive", value: "3"),
            URLQueryItem(name: "sid", value: "\(sid)"),
            URLQueryItem(name: "pid", value: "\(packetID)"),
            URLQueryItem(name: "prid", value: "\(status)"),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "pass", value: pass)
        ]
        guard let url = comps.url else { return }
        packetID += 1
        URLSession.shared.dataTask(with: URLRequest(url: url)).resume()
    }

    private func sendFix(_ fix: Fix) {
        guard let sid = sessionID,
              let user = settings?.liveTrackUsername,
              let pass = KeychainStore.get("xcontestPassword") else { return }
        var comps = URLComponents(string: "\(baseURL)/track.php")!
        comps.queryItems = [
            URLQueryItem(name: "leolive", value: "4"),
            URLQueryItem(name: "sid", value: "\(sid)"),
            URLQueryItem(name: "pid", value: "\(packetID)"),
            URLQueryItem(name: "lat", value: String(format: "%.5f", fix.lat)),
            URLQueryItem(name: "lon", value: String(format: "%.5f", fix.lon)),
            URLQueryItem(name: "alt", value: "\(Int(fix.alt))"),
            URLQueryItem(name: "sog", value: "\(Int(fix.sogKmh))"),
            URLQueryItem(name: "cog", value: "\(Int(fix.cogDeg))"),
            URLQueryItem(name: "tm", value: "\(Int(fix.tm))"),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "pass", value: pass)
        ]
        guard let url = comps.url else { return }
        packetID += 1

        URLSession.shared.dataTask(with: URLRequest(url: url)) { [weak self] _, response, err in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let err = err {
                    self.lastUploadStatus = "Hata: \(err.localizedDescription)"
                    return
                }
                if let http = response as? HTTPURLResponse,
                   (200..<300).contains(http.statusCode) {
                    self.totalFixesSent += 1
                    self.lastUploadAt = Date()
                    // Don't chatter on success — keep status empty so the UI
                    // shows only the counter. If a previous error message was
                    // visible, clear it.
                    if !self.lastUploadStatus.isEmpty,
                       self.lastUploadStatus != "Durduruldu" {
                        self.lastUploadStatus = ""
                    }
                } else if let http = response as? HTTPURLResponse {
                    self.lastUploadStatus = "Sunucu \(http.statusCode)"
                }
            }
        }.resume()
    }

    // MARK: - Upload loop

    private func startUploadTimer() {
        uploadTimer?.invalidate()
        uploadTimer = Timer.scheduledTimer(withTimeInterval: uploadInterval, repeats: true) { [weak self] _ in
            self?.flushPending()
        }
    }

    private func flushPending() {
        lock.lock()
        let fixes = pendingFixes
        pendingFixes.removeAll()
        lock.unlock()
        // Send the newest one only — LiveTrack24 spec expects periodic points,
        // and sending every buffered fix would multiply traffic. We send the
        // most recent fix per cycle; if the pilot wants denser logging, lower
        // `uploadInterval`. This matches most LT24 clients.
        if let f = fixes.last {
            sendFix(f)
        }
    }

    // MARK: - Helpers

    private func liveTrack24VehicleType(for type: GliderType) -> Int {
        switch type {
        case .paraglider:  return 1
        case .hangGlider:  return 2
        case .glider:      return 8
        case .paramotor:   return 16
        }
    }

    private func buildGliderName(_ s: AppSettings) -> String {
        var parts: [String] = []
        if !s.gliderBrandModel.isEmpty {
            parts.append(s.gliderBrandModel)
        } else {
            parts.append(s.gliderType.rawValue)
        }
        if s.gliderCertification != .none {
            parts.append("(\(s.gliderCertification.rawValue))")
        }
        return parts.joined(separator: " ")
    }
}
