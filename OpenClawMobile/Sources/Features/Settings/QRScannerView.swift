import AVFoundation
import SwiftUI

/// Camera QR scanner for setup codes (approved mockup, state 2).
/// Permission denied / no camera (simulator) → `onUnavailable`, and the paste
/// path remains the documented non-camera route (a11y spec, design review 3A).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    var onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.onCode = onCode
        vc.onUnavailable = onUnavailable
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCode: ((String) -> Void)?
        var onUnavailable: (() -> Void)?
        private let session = AVCaptureSession()
        private var reported = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.startSession() : self?.onUnavailable?() }
            }
        }

        private func startSession() {
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                onUnavailable?() // simulator or hardware failure
                return
            }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { onUnavailable?(); return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !reported,
                  let qr = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
                  let value = qr.stringValue else { return }
            reported = true
            session.stopRunning()
            onCode?(value)
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning { session.stopRunning() }
        }
    }
}
