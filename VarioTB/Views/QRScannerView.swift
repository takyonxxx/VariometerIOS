import SwiftUI
import AVFoundation
import UIKit

/// SwiftUI wrapper around an AVFoundation QR code scanner.
///
/// Opens a full-screen camera preview and calls `onScan(payload)` when a
/// QR code is detected. Calls `onCancel()` if the user hits the ✕ button.
///
/// Requires NSCameraUsageDescription in Info.plist.
struct QRScannerView: UIViewControllerRepresentable {
    var onScan: (String) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let vc = QRScannerViewController()
        vc.delegate = context.coordinator
        vc.onCancel = onCancel
        return vc
    }

    func updateUIViewController(_ vc: QRScannerViewController, context: Context) {}

    final class Coordinator: NSObject, QRScannerDelegate {
        let onScan: (String) -> Void
        private var handled = false
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }
        func didFindCode(_ code: String) {
            guard !handled else { return }
            handled = true
            onScan(code)
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func didFindCode(_ code: String)
}

/// UIKit controller that drives the AVCaptureSession and displays the
/// preview layer. Detects `.qr` metadata and reports the string value.
final class QRScannerViewController: UIViewController,
                                     AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?
    var onCancel: (() -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        addOverlay()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async {
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showCameraUnavailable()
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showCameraUnavailable()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.layer.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        self.captureSession = session
        self.previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func addOverlay() {
        // Cancel button
        let cancel = UIButton(type: .system)
        cancel.setTitle("✕", for: .normal)
        cancel.setTitleColor(.white, for: .normal)
        cancel.titleLabel?.font = .systemFont(ofSize: 28, weight: .bold)
        cancel.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        cancel.layer.cornerRadius = 22
        cancel.translatesAutoresizingMaskIntoConstraints = false
        cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        view.addSubview(cancel)
        NSLayoutConstraint.activate([
            cancel.widthAnchor.constraint(equalToConstant: 44),
            cancel.heightAnchor.constraint(equalToConstant: 44),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
        ])

        // Instruction label
        let label = UILabel()
        label.text = "QR kodu kameraya tutun"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        label.layer.cornerRadius = 8
        label.clipsToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -32),
            label.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32),
            label.heightAnchor.constraint(equalToConstant: 44),
        ])

        // Viewfinder (white rounded rect in the middle)
        let finder = UIView()
        finder.layer.borderColor = UIColor.white.cgColor
        finder.layer.borderWidth = 3
        finder.layer.cornerRadius = 16
        finder.isUserInteractionEnabled = false
        finder.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(finder)
        NSLayoutConstraint.activate([
            finder.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            finder.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            finder.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.72),
            finder.heightAnchor.constraint(equalTo: finder.widthAnchor),
        ])
    }

    @objc private func cancelTapped() {
        captureSession?.stopRunning()
        onCancel?()
    }

    private func showCameraUnavailable() {
        let ac = UIAlertController(
            title: "Kamera erişimi yok",
            message: "QR kod taraması için kamera izni gerekir. Ayarlar → Gizlilik → Kamera'dan izin verin.",
            preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "Tamam", style: .default) { [weak self] _ in
            self?.onCancel?()
        })
        present(ac, animated: true)
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        captureSession?.stopRunning()
        if let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
           let str = obj.stringValue {
            AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
            delegate?.didFindCode(str)
        }
    }
}
