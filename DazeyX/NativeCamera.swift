// NativeCamera.swift
// Custom AVFoundation camera that saves near-native media. Dazey carries the Heavenzy spoof natively
// for BOTH photos and videos, so no tweak is needed:
//
//  Photos: pick one or more images, switch between them, and each shutter press saves a photo that
//          uses a REAL capture's authentic HEIC container (MakerNote, HDR gain map, Display P3, XMP)
//          with the chosen image's pixels and a GPS/timezone matched to the current (proxy) IP.
//  Videos: pick one or more clips, switch between them, and pressing record plays the chosen clip for
//          its full length while it is re-muxed into a fresh iPhone-style .mov (QuickTime make/model/
//          software + creation time + proxy-IP location). When the clip ends, recording stops and it
//          is saved.
//
// In both cases the source item is deleted from the library after it is used and removed from the
// switcher, since each is meant to be captured once.
//
// Info.plist keys required:
//   NSCameraUsageDescription
//   NSLocationWhenInUseUsageDescription
//   NSPhotoLibraryUsageDescription   (read-write: needed to delete the originals)

import SwiftUI
import AVFoundation
import CoreLocation
import CoreMedia
import Photos
import PhotosUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - One queued spoof source

enum SpoofKind { case photo, video }

struct SpoofItem: Identifiable {
    let id = UUID()
    let kind: SpoofKind
    let image: UIImage?           // photo pixels (photo only)
    let videoURL: URL?            // local copy of the picked clip (video only)
    let duration: Double          // clip length in seconds (video only)
    let assetIdentifier: String?  // PHAsset local id, so the original can be deleted after use
    let thumbnail: UIImage        // small image for the switcher strip

    static func photo(_ image: UIImage, assetIdentifier: String?, thumbnail: UIImage) -> SpoofItem {
        SpoofItem(kind: .photo, image: image, videoURL: nil, duration: 0,
                  assetIdentifier: assetIdentifier, thumbnail: thumbnail)
    }
    static func video(_ url: URL, duration: Double, assetIdentifier: String?, thumbnail: UIImage) -> SpoofItem {
        SpoofItem(kind: .video, image: nil, videoURL: url, duration: duration,
                  assetIdentifier: assetIdentifier, thumbnail: thumbnail)
    }
}

// MARK: - Camera manager

final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let locationManager = CLLocationManager()
    private var device: AVCaptureDevice?

    // Spoof queue.
    @Published var items: [SpoofItem] = []
    @Published var currentIndex: Int = 0
    @Published var isCapturing = false        // photo shutter in flight
    @Published var isRecording = false        // video "recording" in progress
    @Published var recordElapsed: Double = 0  // seconds, for the on-screen timer
    @Published var lastSaved = false

    // Video playback used both as the live "viewfinder" and as the recording clock.
    let previewPlayer = AVPlayer()
    private var recordingItem: SpoofItem?
    private var exportedURL: URL?
    private var exportFinished = false
    private var playbackEnded = false
    private var recordTimer: Timer?

    private var pendingItem: SpoofItem?       // photo capture in flight

    var currentItem: SpoofItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        previewPlayer.actionAtItemEnd = .pause
        NotificationCenter.default.addObserver(self, selector: #selector(playerItemDidReachEnd(_:)),
                                               name: .AVPlayerItemDidPlayToEndTime, object: nil)
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        // Read-write so we can delete the source media after it's "taken".
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            self.sessionQueue.async { self.configure() }
        }
    }

    func stop() {
        previewPlayer.pause()
        sessionQueue.async { self.session.stopRunning() }
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: cam),
              session.canAddInput(input), session.canAddOutput(photoOutput) else {
            session.commitConfiguration(); return
        }
        device = cam
        session.addInput(input)
        session.addOutput(photoOutput)

        if let maxDims = cam.activeFormat.supportedMaxPhotoDimensions.last {
            photoOutput.maxPhotoDimensions = maxDims
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        session.commitConfiguration()
        session.startRunning()

        // Warm up the proxy-IP geolocation so the shutter isn't blocked waiting on it.
        GeoIP.shared.refresh()

        DispatchQueue.main.async {
            self.locationManager.startUpdatingLocation()
            self.locationManager.startUpdatingHeading()
        }
    }

    // MARK: Queue management

    func addPicked(_ results: [PHPickerResult]) {
        for result in results {
            let assetId = result.assetIdentifier
            let provider = result.itemProvider
            if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                loadVideo(provider, assetId: assetId)
            } else if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    guard let self, let image = object as? UIImage else { return }
                    let thumb = image.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? image
                    let item = SpoofItem.photo(image, assetIdentifier: assetId, thumbnail: thumb)
                    self.append(item)
                }
            }
        }
    }

    private func loadVideo(_ provider: NSItemProvider, assetId: String?) {
        provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { [weak self] tmpURL, _ in
            guard let self, let tmpURL else { return }
            // The provided URL is only valid inside this block, so copy it out immediately.
            let ext = tmpURL.pathExtension.isEmpty ? "mov" : tmpURL.pathExtension
            let dest = VideoSpoofEngine.tempDir().appendingPathComponent(UUID().uuidString + "." + ext)
            do { try FileManager.default.copyItem(at: tmpURL, to: dest) } catch { return }

            let asset = AVURLAsset(url: dest)
            let duration = CMTimeGetSeconds(asset.duration)
            let thumb = Self.videoThumbnail(asset: asset) ?? UIImage(systemName: "video") ?? UIImage()
            let item = SpoofItem.video(dest, duration: duration.isFinite ? duration : 0,
                                       assetIdentifier: assetId, thumbnail: thumb)
            self.append(item)
        }
    }

    private func append(_ item: SpoofItem) {
        DispatchQueue.main.async {
            let wasEmpty = self.items.isEmpty
            self.items.append(item)
            if wasEmpty { self.updatePreview() }
        }
    }

    private static func videoThumbnail(asset: AVAsset) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 400, height: 400)
        let seconds = min(0.1, max(0, CMTimeGetSeconds(asset.duration)))
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? generator.copyCGImage(at: time, actualTime: nil) else { return nil }
        return UIImage(cgImage: cg)
    }

    func select(_ index: Int) {
        guard !isRecording, items.indices.contains(index) else { return }
        currentIndex = index
        updatePreview()
    }

    // Point the preview player at the current item if it's a video (looping, muted); otherwise idle.
    private func updatePreview() {
        guard let item = currentItem, item.kind == .video, let url = item.videoURL else {
            previewPlayer.pause()
            previewPlayer.replaceCurrentItem(with: nil)
            return
        }
        previewPlayer.replaceCurrentItem(with: AVPlayerItem(url: url))
        previewPlayer.isMuted = true
        previewPlayer.seek(to: .zero)
        if !isRecording { previewPlayer.play() }
    }

    // MARK: Photo capture

    func capture() {
        guard !isCapturing, let item = currentItem, item.kind == .photo else { return }
        isCapturing = true
        GeoIP.shared.refresh()
        sessionQueue.async {
            let settings: AVCapturePhotoSettings
            if self.photoOutput.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            if self.photoOutput.supportedFlashModes.contains(.auto) {
                settings.flashMode = .auto
            }
            if let conn = self.photoOutput.connection(with: .video),
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
            self.pendingItem = item
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    // MARK: Video recording

    // Plays the chosen clip once for its full length while re-muxing it in the background; when the
    // clip reaches its end, recording stops and the spoofed .mov is saved.
    func record() {
        guard !isRecording, let item = currentItem, item.kind == .video, let url = item.videoURL else { return }
        isRecording = true
        recordElapsed = 0
        playbackEnded = false
        exportFinished = false
        exportedURL = nil
        recordingItem = item

        DispatchQueue.global(qos: .userInitiated).async {
            let geo = GeoIP.shared.ensureFix(timeout: 2.5)
            VideoSpoofEngine.export(sourceURL: url, geo: geo) { outURL in
                DispatchQueue.main.async {
                    self.exportedURL = outURL
                    self.exportFinished = true
                    self.trySaveRecording()
                }
            }
        }

        previewPlayer.isMuted = true
        previewPlayer.seek(to: .zero)
        previewPlayer.play()

        recordTimer?.invalidate()
        let duration = item.duration
        recordTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.recordElapsed += 0.05
            // Safety net: if the end notification is missed, stop shortly past the known duration.
            if duration > 0, self.recordElapsed >= duration + 0.3, !self.playbackEnded {
                self.playbackEnded = true
                self.previewPlayer.pause()
                self.trySaveRecording()
            }
        }
    }

    @objc private func playerItemDidReachEnd(_ note: Notification) {
        guard let item = note.object as? AVPlayerItem, item === previewPlayer.currentItem else { return }
        if isRecording {
            playbackEnded = true
            previewPlayer.pause()
            trySaveRecording()
        } else {
            previewPlayer.seek(to: .zero)
            previewPlayer.play()
        }
    }

    // Proceeds only once BOTH the clip has finished playing and the re-mux has completed.
    private func trySaveRecording() {
        guard isRecording, playbackEnded, exportFinished, let item = recordingItem else { return }
        recordTimer?.invalidate(); recordTimer = nil

        // Fall back to the raw copied clip if the re-mux failed, so recording always produces output.
        let movedExport = exportedURL != nil
        guard let fileURL = exportedURL ?? item.videoURL else {
            finishRecording(saved: false, item: item); return
        }

        let location = (GeoIP.shared.current.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) })
            ?? locationManager.location

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = movedExport   // move our temp export; never move the source copy
            req.addResource(with: .video, fileURL: fileURL, options: options)
            req.creationDate = Date()
            if let location { req.location = location }
        }) { success, _ in
            DispatchQueue.main.async { self.finishRecording(saved: success, item: item) }
        }
    }

    private func finishRecording(saved: Bool, item: SpoofItem) {
        lastSaved = saved
        isRecording = false
        recordElapsed = 0
        recordingItem = nil
        exportedURL = nil
        if saved {
            consume(item)          // deletes original, removes from queue, refreshes preview
        } else {
            updatePreview()
        }
    }

    // MARK: GPS dictionary (shape the native Camera uses; used only for the real baseline encode)

    fileprivate func gpsDictionary() -> [String: Any]? {
        guard let loc = locationManager.location else { return nil }
        let utc = TimeZone(identifier: "UTC")!
        let timeFmt = DateFormatter(); timeFmt.timeZone = utc; timeFmt.dateFormat = "HH:mm:ss.SS"
        let dateFmt = DateFormatter(); dateFmt.timeZone = utc; dateFmt.dateFormat = "yyyy:MM:dd"
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(loc.coordinate.latitude),
            kCGImagePropertyGPSLatitudeRef as String: loc.coordinate.latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(loc.coordinate.longitude),
            kCGImagePropertyGPSLongitudeRef as String: loc.coordinate.longitude >= 0 ? "E" : "W",
            kCGImagePropertyGPSAltitude as String: abs(loc.altitude),
            kCGImagePropertyGPSAltitudeRef as String: loc.altitude >= 0 ? 0 : 1,
            kCGImagePropertyGPSTimeStamp as String: timeFmt.string(from: loc.timestamp),
            kCGImagePropertyGPSDateStamp as String: dateFmt.string(from: loc.timestamp)
        ]
        if let heading = locationManager.heading, heading.trueHeading >= 0 {
            gps[kCGImagePropertyGPSImgDirection as String] = heading.trueHeading
            gps[kCGImagePropertyGPSImgDirectionRef as String] = "T"
        }
        return gps
    }

    // MARK: Consume a used source

    // Remove from the in-app switcher, then delete the original from the library (system confirms the
    // deletion). The spoofed media is already saved, so a cancelled deletion never loses the capture.
    private func consume(_ item: SpoofItem) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items.remove(at: idx)
                if self.currentIndex >= self.items.count {
                    self.currentIndex = max(0, self.items.count - 1)
                }
            }
            self.updatePreview()
        }
        // Clean up the temp copy of a consumed clip.
        if let url = item.videoURL { try? FileManager.default.removeItem(at: url) }

        guard let assetId = item.assetIdentifier else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetId], options: nil)
        guard assets.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        } completionHandler: { _, _ in }
    }
}

// MARK: - Inject GPS without re-encoding (baseline real encode)

private final class GPSCustomizer: NSObject, AVCapturePhotoFileDataRepresentationCustomizer {
    let gps: [String: Any]?
    init(gps: [String: Any]?) { self.gps = gps }
    func replacementMetadata(for photo: AVCapturePhoto) -> [String: Any]? {
        var meta = photo.metadata
        if let gps { meta[kCGImagePropertyGPSDictionary as String] = gps }
        return meta
    }
}

// MARK: - Photo capture delegate + save

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        defer { DispatchQueue.main.async { self.isCapturing = false } }
        let item = pendingItem
        pendingItem = nil
        guard error == nil else { return }

        let customizer = GPSCustomizer(gps: gpsDictionary())
        guard let realData = photo.fileDataRepresentation(with: customizer) else { return }

        // Swap the real capture's pixels for the chosen image + proxy-IP GPS/time. Fall back to the
        // genuine photo only if cloning fails (rare), so the shutter always produces something.
        let geo = GeoIP.shared.ensureFix(timeout: 2.5)
        let outData: Data
        if let item, let image = item.image, let swapped = SpoofEngine.clone(real: realData, with: image, geo: geo) {
            outData = swapped
        } else {
            outData = realData
        }

        PHPhotoLibrary.shared().performChanges({
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, data: outData, options: nil)
        }) { success, _ in
            DispatchQueue.main.async { self.lastSaved = success }
            if success, let item { self.consume(item) }
        }
    }
}

extension CameraManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.startUpdatingLocation()
            manager.startUpdatingHeading()
        }
    }
}

// MARK: - Camera preview

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - Video preview (the chosen clip shown as the viewfinder)

struct PlayerPreview: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PlayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

// MARK: - Multi-select picker (photos + videos)

struct MultiImagePicker: UIViewControllerRepresentable {
    var onPicked: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .any(of: [.images, .videos])
        config.selectionLimit = 0            // 0 = unlimited multi-select
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: MultiImagePicker
        init(_ parent: MultiImagePicker) { self.parent = parent }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            parent.onPicked(results)
        }
    }
}

// MARK: - SwiftUI screen

struct CameraView: View {
    @EnvironmentObject private var auth: AuthManager
    @StateObject private var camera = CameraManager()
    @State private var showingPicker = false
    @State private var showingAccount = false

    private var accountEmail: String {
        if case .signedIn(let email) = auth.state { return email }
        return ""
    }

    var body: some View {
        ZStack {
            CameraPreview(session: camera.session).ignoresSafeArea()

            // Show the current item as if it were the live camera.
            if let item = camera.currentItem {
                if item.kind == .video {
                    PlayerPreview(player: camera.previewPlayer)
                        .ignoresSafeArea()
                } else if let image = item.image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .ignoresSafeArea()
                        .clipped()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                    Text("Tap + to add photos or videos to spoof").font(.subheadline)
                }
                .foregroundStyle(.white.opacity(0.85))
            }

            VStack {
                HStack {
                    Spacer()
                    Button { showingAccount = true } label: {
                        Image(systemName: "person.crop.circle")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(.black.opacity(0.35)))
                    }
                    .disabled(camera.isRecording)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                if camera.isRecording { recordingBadge }
                Spacer()
                controls
            }
        }
        .confirmationDialog(accountEmail, isPresented: $showingAccount, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) { auth.signOut() }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showingPicker) {
            MultiImagePicker { results in camera.addPicked(results) }
                .ignoresSafeArea()
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var recordingBadge: some View {
        HStack(spacing: 8) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Text(timeString(camera.recordElapsed))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Capsule().fill(.black.opacity(0.45)))
        .padding(.top, 16)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private var controls: some View {
        VStack(spacing: 14) {
            if !camera.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(camera.items.enumerated()), id: \.element.id) { index, item in
                                thumbnail(for: item, index: index)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: camera.currentIndex) { _, newValue in
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
                .frame(height: 64)
                .disabled(camera.isRecording)
            }

            HStack {
                Button { showingPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
                .disabled(camera.isRecording)

                Spacer()

                shutter

                Spacer()

                // Balance the row; show remaining count.
                Text(camera.items.isEmpty ? "" : "\(camera.currentIndex + 1)/\(camera.items.count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    @ViewBuilder
    private var shutter: some View {
        if camera.currentItem?.kind == .video {
            Button(action: camera.record) {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 4).frame(width: 76, height: 76)
                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 6).fill(.red).frame(width: 28, height: 28)
                    } else {
                        Circle().fill(.red).frame(width: 60, height: 60)
                    }
                }
            }
            .disabled(camera.isRecording)
        } else {
            Button(action: camera.capture) {
                Circle().strokeBorder(.white, lineWidth: 4)
                    .background(Circle().fill(.white.opacity(camera.currentItem == nil ? 0.3 : 0.9)).padding(6))
                    .frame(width: 76, height: 76)
            }
            .disabled(camera.currentItem == nil || camera.isCapturing)
        }
    }

    private func thumbnail(for item: SpoofItem, index: Int) -> some View {
        Image(uiImage: item.thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Circle().fill(.black.opacity(0.5)))
                        .padding(4)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(index == camera.currentIndex ? Color.yellow : Color.white.opacity(0.4),
                            lineWidth: index == camera.currentIndex ? 3 : 1)
            )
            .id(index)
            .onTapGesture { camera.select(index) }
    }
}
