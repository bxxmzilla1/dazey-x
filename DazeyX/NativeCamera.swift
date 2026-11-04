// NativeCamera.swift
// Custom AVFoundation camera that saves near-native photos (HEIC, full-res, original EXIF +
// MakerApple, GPS). Dazey now also carries the Heavenzy spoof natively: pick one or more photos from
// the library, switch between them, and each shutter press saves a photo that uses the REAL capture's
// authentic HEIC container (MakerNote, HDR gain map, Display P3, XMP) with the chosen image's pixels
// and a GPS/timezone matched to the current (proxy) IP. After a shot, that source photo is deleted
// from the library and removed from the switcher, since each is meant to be "taken" once.
//
// Info.plist keys required:
//   NSCameraUsageDescription
//   NSLocationWhenInUseUsageDescription
//   NSPhotoLibraryUsageDescription   (read-write: needed to delete the originals)

import SwiftUI
import AVFoundation
import CoreLocation
import Photos
import PhotosUI
import ImageIO

// MARK: - One queued spoof source

struct SpoofItem: Identifiable {
    let id = UUID()
    let image: UIImage            // full image used to build the capture
    let assetIdentifier: String?  // PHAsset local id, so the original can be deleted after use
    let thumbnail: UIImage        // small image for the switcher strip
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
    @Published var isCapturing = false
    @Published var lastSaved = false

    private var pendingItem: SpoofItem?

    var currentItem: SpoofItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func start() {
        locationManager.requestWhenInUseAuthorization()
        // Read-write so we can delete the source photos after they're "taken".
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in }

        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { return }
            self.sessionQueue.async { self.configure() }
        }
    }

    func stop() {
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
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                guard let self, let image = object as? UIImage else { return }
                let thumb = image.preparingThumbnail(of: CGSize(width: 200, height: 200)) ?? image
                let item = SpoofItem(image: image, assetIdentifier: assetId, thumbnail: thumb)
                DispatchQueue.main.async { self.items.append(item) }
            }
        }
    }

    func select(_ index: Int) {
        guard items.indices.contains(index) else { return }
        currentIndex = index
    }

    // MARK: Capture

    func capture() {
        guard !isCapturing, let item = currentItem else { return }
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
    // deletion). The spoofed photo is already saved, so a cancelled deletion never loses the capture.
    private func consume(_ item: SpoofItem) {
        DispatchQueue.main.async {
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items.remove(at: idx)
                if self.currentIndex >= self.items.count {
                    self.currentIndex = max(0, self.items.count - 1)
                }
            }
        }
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

// MARK: - Capture delegate + save

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
        if let item, let swapped = SpoofEngine.clone(real: realData, with: item.image, geo: geo) {
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

// MARK: - Preview

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

// MARK: - Multi-select picker

struct MultiImagePicker: UIViewControllerRepresentable {
    var onPicked: ([PHPickerResult]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
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

            // Show the currently selected image as if it were the live camera.
            if let item = camera.currentItem {
                Image(uiImage: item.image)
                    .resizable()
                    .scaledToFill()
                    .ignoresSafeArea()
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 40))
                    Text("Tap + to add photos to spoof").font(.subheadline)
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
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
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

    private var controls: some View {
        VStack(spacing: 14) {
            if !camera.items.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(camera.items.enumerated()), id: \.element.id) { index, item in
                                Image(uiImage: item.thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(index == camera.currentIndex ? Color.yellow : Color.white.opacity(0.4),
                                                    lineWidth: index == camera.currentIndex ? 3 : 1)
                                    )
                                    .id(index)
                                    .onTapGesture { camera.select(index) }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .onChange(of: camera.currentIndex) { _, newValue in
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
                .frame(height: 64)
            }

            HStack {
                Button { showingPicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(.white.opacity(0.18)))
                }

                Spacer()

                Button(action: camera.capture) {
                    Circle().strokeBorder(.white, lineWidth: 4)
                        .background(Circle().fill(.white.opacity(camera.currentItem == nil ? 0.3 : 0.9)).padding(6))
                        .frame(width: 76, height: 76)
                }
                .disabled(camera.currentItem == nil || camera.isCapturing)

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
}
