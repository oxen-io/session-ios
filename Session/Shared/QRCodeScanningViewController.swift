// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import SessionUIKit
import SessionUtilitiesKit

protocol QRScannerDelegate: AnyObject {
    func controller(_ controller: QRCodeScanningViewController, didDetectQRCodeWith string: String, onSuccess: (() -> ())?, onError: (() -> ())?)
}

class QRCodeScanningViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    public weak var scanDelegate: QRScannerDelegate?
    
    private let captureQueue: DispatchQueue = DispatchQueue.global(qos: .default)
    private var capture: AVCaptureSession?
    private var captureLayer: AVCaptureVideoPreviewLayer?
    private var captureEnabled: Bool = false
    private var shouldResumeCapture: Bool = false
    
    // MARK: - Initialization
    
    deinit {
        self.captureLayer?.removeFromSuperlayer()
    }
    
    // MARK: - Components
    
    private let maskingView: UIView = UIView()
    
    private lazy var maskLayer: CAShapeLayer = {
        let result: CAShapeLayer = CAShapeLayer()
        result.fillRule = .evenOdd
        result.themeFillColor = .black
        result.opacity = 0.32
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    override func loadView() {
        super.loadView()
        
        self.view.addSubview(maskingView)
        
        maskingView.layer.addSublayer(maskLayer)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        if captureEnabled || shouldResumeCapture {
            self.startCapture()
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        self.stopCapture()
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        captureLayer?.frame = self.view.bounds
        
        if maskingView.frame != self.view.bounds {
            // Add a circular mask
            let path: UIBezierPath = UIBezierPath(rect: self.view.bounds)
            let radius: CGFloat = ((min(self.view.bounds.size.width, self.view.bounds.size.height) * 0.5) - Values.largeSpacing)

            // Center the circle's bounding rectangle
            let circleRect: CGRect = CGRect(
                x: ((self.view.bounds.size.width * 0.5) - radius),
                y: ((self.view.bounds.size.height * 0.5) - radius),
                width: (radius * 2),
                height: (radius * 2)
            )
            let clippingPath: UIBezierPath = UIBezierPath.init(
                roundedRect: circleRect,
                cornerRadius: 16
            )
            path.append(clippingPath)
            path.usesEvenOddFillRule = true
            
            maskLayer.path = path.cgPath
        }
    }

    // MARK: - Functions
    
    public func startCapture() {
        self.captureEnabled = true
        
        // Note: The simulator doesn't support video but if we do try to start an
        // AVCaptureSession it seems to hang on that particular thread indefinitely
        // this will prevent us from trying to start a session on the simulator
        #if targetEnvironment(simulator)
        #else
            if self.capture == nil {
                self.captureQueue.async { [weak self] in
                    let maybeDevice: AVCaptureDevice? = {
                        if let result = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
                            return result
                        }
                        
                        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                    }()
                    
                    // Set the input device to autoFocus (since we don't have the interaction setup for
                    // doing it manually)
                    do {
                        try maybeDevice?.lockForConfiguration()
                        maybeDevice?.focusMode = .continuousAutoFocus
                        maybeDevice?.unlockForConfiguration()
                    }
                    catch {}
                    
                    // Device input
                    guard
                        let device: AVCaptureDevice = maybeDevice,
                        let input: AVCaptureInput = try? AVCaptureDeviceInput(device: device)
                    else {
                        return SNLog("Failed to retrieve the device for enabling the QRCode scanning camera")
                    }
                    
                    // Image output
                    let output: AVCaptureVideoDataOutput = AVCaptureVideoDataOutput()
                    output.alwaysDiscardsLateVideoFrames = true
                    
                    // Metadata output the session
                    let metadataOutput: AVCaptureMetadataOutput = AVCaptureMetadataOutput()
                    metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
                    
                    let capture: AVCaptureSession = AVCaptureSession()
                    capture.beginConfiguration()
                    if capture.canAddInput(input) { capture.addInput(input) }
                    if capture.canAddOutput(output) { capture.addOutput(output) }
                    if capture.canAddOutput(metadataOutput) { capture.addOutput(metadataOutput) }
                    
                    guard !capture.inputs.isEmpty && capture.outputs.count == 2 else {
                        return SNLog("Failed to attach the input/output to the capture session")
                    }
                    
                    guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
                        return SNLog("The output is unable to process QR codes")
                    }
                    
                    // Specify that we want to capture QR Codes (Needs to be done after being added
                    // to the session, 'availableMetadataObjectTypes' is empty beforehand)
                    metadataOutput.metadataObjectTypes = [.qr]
                    
                    capture.commitConfiguration()
                    
                    // Create the layer for rendering the camera video
                    let layer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: capture)
                    layer.videoGravity = AVLayerVideoGravity.resizeAspectFill

                    // Start running the capture session
                    capture.startRunning()

                    DispatchQueue.main.async {
                        layer.frame = (self?.view.bounds ?? .zero)
                        self?.view.layer.addSublayer(layer)
                        
                        if let maskingView: UIView = self?.maskingView {
                            self?.view.bringSubviewToFront(maskingView)
                        }
                    
                        self?.capture = capture
                        self?.captureLayer = layer
                    }
                }
            }
            else {
                self.capture?.startRunning()
            }
        #endif
    }

    private func stopCapture() {
        self.captureEnabled = false
        self.captureQueue.async { [weak self] in
            self?.capture?.stopRunning()
        }
    }
    
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard
            self.captureEnabled,
            let metadata: AVMetadataObject = metadataObjects.first(where: { ($0 as? AVMetadataMachineReadableCodeObject)?.type == .qr }),
            let qrCodeInfo: AVMetadataMachineReadableCodeObject = metadata as? AVMetadataMachineReadableCodeObject,
            let qrCode: String = qrCodeInfo.stringValue
        else { return }
        
        self.stopCapture()
        
        // Vibrate
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)

        self.scanDelegate?.controller(
            self,
            didDetectQRCodeWith: qrCode,
            onSuccess: { [weak self] in
                self?.shouldResumeCapture = true
            },
            onError: { [weak self] in
                self?.startCapture()
            }
        )
    }
}

// MARK: SwiftUI
import SwiftUI

struct QRCodeScanningVC_SwiftUI: UIViewControllerRepresentable {
    typealias UIViewControllerType = QRCodeScanningViewController
    
    let scanQRCodeVC = QRCodeScanningViewController()
    var didDetectQRCode: (String, (() -> ())?, (() -> ())?) -> ()
    
    func makeUIViewController(context: Context) -> QRCodeScanningViewController {
        return scanQRCodeVC
    }
    
    func updateUIViewController(_ scanQRCodeVC: QRCodeScanningViewController, context: Context) {
        scanQRCodeVC.startCapture()
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(
            scanQRCodeVC: scanQRCodeVC,
            didDetectQRCode: didDetectQRCode
        )
    }
    
    class Coordinator: NSObject, QRScannerDelegate {
        var didDetectQRCode: (String, (() -> ())?, (() -> ())?) -> ()
        
        init(
            scanQRCodeVC: QRCodeScanningViewController,
            didDetectQRCode: @escaping (String, (() -> ())?, (() -> ())?) -> ()
        ) {
            self.didDetectQRCode = didDetectQRCode
            super.init()
            scanQRCodeVC.scanDelegate = self
        }
        
        func controller(_ controller: QRCodeScanningViewController, didDetectQRCodeWith string: String, onSuccess: (() -> ())?, onError: (() -> ())?) {
            didDetectQRCode(string, onSuccess, onError)
        }
    }
}
