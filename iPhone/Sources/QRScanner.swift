@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The camera, reading QR codes. Reports every code it reads; stops while `isActive` is false.
struct QRScanner: UIViewRepresentable {
    var isActive: Bool
    let found: (String) -> Void

    func makeUIView(context: Context) -> ScannerView {
        let view = ScannerView()
        view.found = found
        return view
    }

    func updateUIView(_ view: ScannerView, context: Context) {
        view.found = found
        view.setActive(isActive)
    }

    static func dismantleUIView(_ view: ScannerView, coordinator: ()) {
        view.setActive(false)
    }

    final class ScannerView: UIView, AVCaptureMetadataOutputObjectsDelegate {
        var found: ((String) -> Void)?
        nonisolated(unsafe) private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "OpenMae.scanner")
        nonisolated(unsafe) private var configured = false

        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        private var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        func setActive(_ active: Bool) {
            let session = session
            queue.async { [weak self] in
                guard let self else { return }
                if active {
                    if !self.configured { self.configure() }
                    if !session.isRunning { session.startRunning() }
                } else if session.isRunning {
                    session.stopRunning()
                }
            }
        }

        /// On the scanner's queue.
        nonisolated private func configure() {
            configured = true
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
            else { return }
            session.beginConfiguration()
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.preview.session = self.session
                self.preview.videoGravity = .resizeAspectFill
            }
        }

        nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput,
                                        didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection)
        {
            let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
            MainActor.assumeIsolated {
                codes.forEach { found?($0) }
            }
        }
    }
}

/// Camera access, asked the first time the scanner shows.
enum CameraAccess {
    /// iOS has not asked the user yet: `request` would.
    static var mustAsk: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined }

    static func request() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}
