// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

final class ScanQRCodeWrapperVC: BaseVC {
    var delegate: (UIViewController & QRScannerDelegate)? = nil
    var isPresentedModally = false
    
    private let scanQRCodeVC = QRCodeScanningViewController()
    
    // MARK: - Lifecycle
    
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    override init(nibName: String?, bundle: Bundle?) {
        preconditionFailure("Use init(message:) instead.")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        title = "qrScan".localized()
        
        // Set up navigation bar if needed
        if isPresentedModally {
            navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .stop, target: self, action: #selector(close))
        }
        
        // Set up scan QR code VC
        scanQRCodeVC.scanDelegate = delegate
        let scanQRCodeVCView = scanQRCodeVC.view!
        view.addSubview(scanQRCodeVCView)
        scanQRCodeVCView.pin(to: view)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.scanQRCodeVC.startCapture()
    }
    
    // MARK: - Interaction
    
    @objc private func close() {
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
    
    public func startCapture() {
        self.scanQRCodeVC.startCapture()
    }
}
