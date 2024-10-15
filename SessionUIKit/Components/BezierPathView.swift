// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public class BezierPathView: UIView {
    public var configureShapeLayer: ((CAShapeLayer, CGRect) -> ())? {
        didSet {
            updateLayers()
        }
    }
    
    public override var frame: CGRect {
        didSet {
            guard oldValue.size != frame.size else { return }
            
            updateLayers()
        }
    }
    
    public override var bounds: CGRect {
        didSet {
            guard oldValue.size != frame.size else { return }
            
            updateLayers()
        }
    }
    
    // MARK: - Initialization
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        
        self.isOpaque = false
        self.isUserInteractionEnabled = false
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        
        self.isOpaque = false
        self.isUserInteractionEnabled = false
    }
    
    // MARK: - Functions
    
    private func updateLayers() {
        guard bounds.size.width > 0 && bounds.size.height > 0 else { return }

        layer.sublayers?.forEach { $0.removeFromSuperlayer() }

        // Prevent the shape layer from animating changes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        
        let shapeLayer: CAShapeLayer = CAShapeLayer()
        configureShapeLayer?(shapeLayer, bounds)
        layer.addSublayer(shapeLayer)
        
        CATransaction.commit()
        setNeedsDisplay()
    }
}
