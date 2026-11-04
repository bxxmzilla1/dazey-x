// SpoofEngine.swift
// Native port of the Heavenzy camera-spoof pipeline, so Dazey can replace a capture with a chosen
// image WITHOUT any tweak/injection. Given the REAL photo's file data (a genuine iPhone HEIC with
// Apple MakerNote, HDR gain map / depth, Display P3 profile and XMP), it swaps only the primary
// image pixels for the chosen image and rewrites GPS + timestamps to the current public-IP location
// and timezone - so the saved photo keeps an authentic container but shows the spoofed picture.

import UIKit
import ImageIO
import CoreImage
import CryptoKit
import UniformTypeIdentifiers

struct GeoFix {
    let latitude: Double
    let longitude: Double
    let offsetSeconds: Int
    let timezoneName: String
}

enum SpoofEngine {
    private static let ciContext = CIContext(options: nil)

    // MARK: Public entry

    /// Clone `real` (a genuine HEIC) swapping the primary image for `image`, applying `geo`.
    static func clone(real: Data, with image: UIImage, geo: GeoFix?) -> Data? {
        guard !real.isEmpty,
              let src = CGImageSourceCreateWithData(real as CFData, nil),
              let utiCF = CGImageSourceGetType(src) else { return nil }
        let uti = utiCF as String
        guard uti == UTType.heic.identifier || uti == "public.heif" else { return nil }

        var props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        let W = (props[kCGImagePropertyPixelWidth as String] as? Int) ?? 0
        let H = (props[kCGImagePropertyPixelHeight as String] as? Int) ?? 0
        var o = (props[kCGImagePropertyOrientation as String] as? Int) ?? 1
        if o < 1 || o > 8 { o = 1 }
        guard W > 0, H > 0,
              let stored = storedPixels(image: image, width: W, height: H, orientation: o) else { return nil }

        applyGeoAndTime(&props, geo: geo)

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, stored, props as CFDictionary)

        // Keep the authentic auxiliary images (HDR gain map, depth, disparity, portrait matte): they
        // come from the same capture as the MakerNote, so the main<->aux pairing stays consistent.
        let auxTypes: [CFString] = [
            kCGImageAuxiliaryDataTypeHDRGainMap,
            kCGImageAuxiliaryDataTypeDepth,
            kCGImageAuxiliaryDataTypeDisparity,
            kCGImageAuxiliaryDataTypePortraitEffectsMatte
        ]
        for type in auxTypes {
            if let aux = CGImageSourceCopyAuxiliaryDataInfoAtIndex(src, 0, type) {
                CGImageDestinationAddAuxiliaryDataInfo(dest, type, aux)
            }
        }

        return CGImageDestinationFinalize(dest) ? (out as Data) : nil
    }

    // MARK: Pixels

    // EXIF orientation is its own inverse except the 90-degree pair 6<->8.
    private static func inverseOrientation(_ o: Int) -> Int {
        if o == 6 { return 8 }
        if o == 8 { return 6 }
        return (1...8).contains(o) ? o : 1
    }

    private static func normalizedUp(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: fmt)
        let up = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
        return up.cgImage
    }

    private static func aspectFill(_ ci: CIImage, width W: Int, height H: Int) -> CIImage {
        let ext = ci.extent
        guard ext.width > 0, ext.height > 0 else { return ci }
        let scale = max(CGFloat(W) / ext.width, CGFloat(H) / ext.height)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let s = scaled.extent
        let tx = (s.width - CGFloat(W)) / 2.0
        let ty = (s.height - CGFloat(H)) / 2.0
        let moved = scaled.transformed(by: CGAffineTransform(translationX: -s.origin.x - tx, y: -s.origin.y - ty))
        return moved.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    }

    // Render `image` into the real capture's stored pixel geometry (WxH, orientation o) in Display P3,
    // so swapping it into the real container keeps dimensions, orientation and color space intact.
    private static func storedPixels(image: UIImage, width W: Int, height H: Int, orientation o: Int) -> CGImage? {
        guard let up = normalizedUp(image) else { return nil }
        let inv = inverseOrientation(o)
        let oriented = CIImage(cgImage: up).oriented(CGImagePropertyOrientation(rawValue: UInt32(inv)) ?? .up)
        let filled = aspectFill(oriented, width: W, height: H)
        let p3 = CGColorSpace(name: CGColorSpace.displayP3) ?? CGColorSpaceCreateDeviceRGB()
        return ciContext.createCGImage(filled, from: CGRect(x: 0, y: 0, width: W, height: H),
                                       format: .RGBA8, colorSpace: p3)
    }

    // MARK: Geo + time

    private static func hashUnit(_ seed: String) -> Double {
        let digest = SHA256.hash(data: Data(seed.utf8))
        var v: UInt64 = 0
        for (i, b) in digest.enumerated() where i < 8 { v = (v << 8) | UInt64(b) }
        return Double(v % 1_000_000) / 1_000_000.0
    }

    private static func gpsDict(latitude: Double, longitude: Double, date: Date) -> [String: Any] {
        let base = String(format: "%.4f,%.4f", latitude, longitude)
        let jLat = (hashUnit(base + "|la") - 0.5) * 0.0016   // ~±90 m
        let jLon = (hashUnit(base + "|lo") - 0.5) * 0.0016
        let alt  = 8.0 + hashUnit(base + "|al") * 180.0       // 8..188 m
        let hErr = 4.0 + hashUnit(base + "|he") * 26.0        // 4..30 m
        let head = hashUnit(base + "|hd") * 360.0
        let lat = latitude + jLat
        let lon = longitude + jLon

        let utc = TimeZone(identifier: "UTC")
        let posix = Locale(identifier: "en_US_POSIX")
        let time = DateFormatter(); time.locale = posix; time.timeZone = utc; time.dateFormat = "HH:mm:ss.SS"
        let day = DateFormatter(); day.locale = posix; day.timeZone = utc; day.dateFormat = "yyyy:MM:dd"

        return [
            kCGImagePropertyGPSLatitude as String: abs(lat),
            kCGImagePropertyGPSLatitudeRef as String: lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(lon),
            kCGImagePropertyGPSLongitudeRef as String: lon >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude as String: alt,
            kCGImagePropertyGPSAltitudeRef as String: 0,
            kCGImagePropertyGPSHPositioningError as String: hErr,
            kCGImagePropertyGPSImgDirection as String: head,
            kCGImagePropertyGPSImgDirectionRef as String: "T",
            kCGImagePropertyGPSDestBearing as String: head,
            kCGImagePropertyGPSDestBearingRef as String: "T",
            kCGImagePropertyGPSTimeStamp as String: time.string(from: date),
            kCGImagePropertyGPSDateStamp as String: day.string(from: date)
        ]
    }

    // Rewrite GPS + every EXIF/TIFF timestamp so they agree with the proxy IP's timezone. Without a
    // fix, GPS is removed rather than leaking the device's real location.
    private static func applyGeoAndTime(_ props: inout [String: Any], geo: GeoFix?) {
        guard let geo = geo else {
            props[kCGImagePropertyGPSDictionary as String] = nil
            return
        }
        let now = Date()
        props[kCGImagePropertyGPSDictionary as String] = gpsDict(latitude: geo.latitude, longitude: geo.longitude, date: now)

        let tz = TimeZone(secondsFromGMT: geo.offsetSeconds) ?? TimeZone(identifier: "UTC")!
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = tz
        local.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let localStr = local.string(from: now)

        let off = geo.offsetSeconds
        let offStr = String(format: "%@%02d:%02d", off >= 0 ? "+" : "-", abs(off) / 3600, (abs(off) % 3600) / 60)

        var exif = (props[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]
        exif[kCGImagePropertyExifDateTimeOriginal as String] = localStr
        exif[kCGImagePropertyExifDateTimeDigitized as String] = localStr
        exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offStr
        exif[kCGImagePropertyExifOffsetTimeDigitized as String] = offStr
        exif[kCGImagePropertyExifOffsetTime as String] = offStr
        props[kCGImagePropertyExifDictionary as String] = exif

        var tiff = (props[kCGImagePropertyTIFFDictionary as String] as? [String: Any]) ?? [:]
        tiff[kCGImagePropertyTIFFDateTime as String] = localStr
        props[kCGImagePropertyTIFFDictionary as String] = tiff
    }
}

// MARK: - Proxy-aware IP geolocation

// Resolves the current public-IP location over the app's own network, so behind a proxy/VPN it
// reports the proxy's exit IP. Used to keep the photo's GPS + clock consistent with that IP.
final class GeoIP {
    static let shared = GeoIP()

    private let lock = NSLock()
    private var fix: GeoFix?
    private var fetchedAt: Date?
    private let url = URL(string: "https://ipwho.is/?fields=success,latitude,longitude,timezone")!

    var current: GeoFix? { lock.lock(); defer { lock.unlock() }; return fix }

    private var isFresh: Bool {
        lock.lock(); defer { lock.unlock() }
        guard fix != nil, let at = fetchedAt else { return false }
        return -at.timeIntervalSinceNow < 180
    }

    func refresh() {
        if isFresh { return }
        fetch(completion: nil)
    }

    // Blocks the CURRENT (non-main) thread up to `timeout` for a usable fix. Safe from a capture queue.
    func ensureFix(timeout: TimeInterval) -> GeoFix? {
        if isFresh { return current }
        let sem = DispatchSemaphore(value: 0)
        fetch { sem.signal() }
        _ = sem.wait(timeout: .now() + timeout)
        return current
    }

    private func fetch(completion: (() -> Void)?) {
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            defer { completion?() }
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["success"] as? Bool) == true else { return }
            let lat = (json["latitude"] as? Double) ?? 0
            let lon = (json["longitude"] as? Double) ?? 0
            let tz = json["timezone"] as? [String: Any]
            let offset = (tz?["offset"] as? Int) ?? 0
            let name = (tz?["id"] as? String) ?? ""
            guard lat != 0 || lon != 0 else { return }
            self.lock.lock()
            self.fix = GeoFix(latitude: lat, longitude: lon, offsetSeconds: offset, timezoneName: name)
            self.fetchedAt = Date()
            self.lock.unlock()
        }.resume()
    }
}
