// VideoSpoofEngine.swift
// Video side of the native spoof. Given a picked video, it re-muxes the clip into a fresh QuickTime
// .mov that carries the metadata an iPhone recording would (com.apple.quicktime make / model /
// software / creationdate / location ISO6709), with the creation time + GPS matched to the current
// (proxy) IP. Passthrough is used when possible, so the video/audio streams are copied without
// re-encoding (fast, lossless) and only the container metadata is rewritten.

import UIKit
import AVFoundation
import CoreMedia

enum VideoSpoofEngine {

    /// Re-mux `sourceURL` into a fresh .mov with spoofed iPhone metadata. Returns the output URL
    /// (in a temp dir) on the main-independent completion, or nil on failure.
    static func export(sourceURL: URL, geo: GeoFix?, completion: @escaping (URL?) -> Void) {
        let asset = AVURLAsset(url: sourceURL)
        let presets = AVAssetExportSession.exportPresets(compatibleWith: asset)
        let preset = presets.contains(AVAssetExportPresetPassthrough)
            ? AVAssetExportPresetPassthrough
            : AVAssetExportPresetHighestQuality
        guard let export = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(nil); return
        }

        let outURL = tempDir().appendingPathComponent(UUID().uuidString + ".mov")
        export.outputURL = outURL
        export.outputFileType = .mov
        export.metadata = metadata(geo: geo)
        export.shouldOptimizeForNetworkUse = true

        export.exportAsynchronously {
            if export.status == .completed {
                completion(outURL)
            } else {
                NSLog("[Dazey] video export failed: \(export.error?.localizedDescription ?? "unknown")")
                try? FileManager.default.removeItem(at: outURL)
                completion(nil)
            }
        }
    }

    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DazeySpoof", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Metadata

    private static func metadata(geo: GeoFix?) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = [
            string(.quickTimeMetadataMake, "Apple"),
            string(.quickTimeMetadataModel, deviceModel()),
            string(.quickTimeMetadataSoftware, UIDevice.current.systemVersion)
        ]

        let tz = geo.flatMap { TimeZone(secondsFromGMT: $0.offsetSeconds) } ?? TimeZone.current
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = tz
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        items.append(string(.quickTimeMetadataCreationDate, fmt.string(from: Date())))

        if let geo {
            items.append(string(.quickTimeMetadataLocationISO6709,
                                iso6709(latitude: geo.latitude, longitude: geo.longitude, altitude: 8.0)))
        }
        return items
    }

    private static func string(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value as NSString
        item.dataType = kCMMetadataBaseDataType_UTF8 as String
        return item
    }

    // "+34.0522-118.2437+008.000/" — the ISO 6709 string iPhone writes into quicktime.location.
    private static func iso6709(latitude: Double, longitude: Double, altitude: Double) -> String {
        String(format: "%+.4f%+.4f%+.3f/", latitude, longitude, altitude)
    }

    private static func deviceModel() -> String {
        var sys = utsname()
        uname(&sys)
        let machine = Mirror(reflecting: sys.machine).children.compactMap { child -> Character? in
            guard let code = child.value as? Int8, code != 0 else { return nil }
            return Character(UnicodeScalar(UInt8(code)))
        }
        let model = String(machine)
        return model.isEmpty ? "iPhone15,2" : model
    }
}
