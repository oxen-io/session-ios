// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Enums

public protocol ConstraintUtilitiesEdge {}

public extension UIView {
    enum HorizontalEdge: ConstraintUtilitiesEdge { case left, leading, right, trailing }
    enum VerticalEdge: ConstraintUtilitiesEdge { case top, bottom }
    enum HorizontalMargin: ConstraintUtilitiesEdge { case left, leading, right, trailing }
    enum VerticalMargin: ConstraintUtilitiesEdge { case top, bottom }
    enum Direction { case horizontal, vertical }
    enum VerticalDirection { case vertical }
    enum HorizontalDirection { case horizontal }
    enum Dimension { case width, height }
}

// MARK: - Anchorable

public protocol Anchorable {
    func anchor(from edge: UIView.HorizontalEdge) -> NSLayoutXAxisAnchor
    func anchor(from edge: UIView.VerticalEdge) -> NSLayoutYAxisAnchor
}

extension UIView: Anchorable {
    public func anchor(from edge: UIView.HorizontalEdge) -> NSLayoutXAxisAnchor {
        switch edge {
            case .left: return leftAnchor
            case .leading: return leadingAnchor
            case .right: return rightAnchor
            case .trailing: return trailingAnchor
        }
    }
    
    public func anchor(from edge: UIView.VerticalEdge) -> NSLayoutYAxisAnchor {
        switch edge {
            case .top: return topAnchor
            case .bottom: return bottomAnchor
        }
    }
    
    public func attribute(from edge: UIView.HorizontalEdge) -> NSLayoutConstraint.Attribute {
        switch edge {
            case .left: return .left
            case .leading: return .leading
            case .right: return .right
            case .trailing: return .trailing
        }
    }
    
    public func attribute(from edge: UIView.HorizontalMargin) -> NSLayoutConstraint.Attribute {
        switch edge {
            case .left: return .leftMargin
            case .leading: return .leadingMargin
            case .right: return .rightMargin
            case .trailing: return .trailingMargin
        }
    }
    
    public func attribute(from edge: UIView.VerticalEdge) -> NSLayoutConstraint.Attribute {
        switch edge {
            case .top: return .top
            case .bottom: return .bottom
        }
    }
    
    public func attribute(from edge: UIView.VerticalMargin) -> NSLayoutConstraint.Attribute {
        switch edge {
            case .top: return .topMargin
            case .bottom: return .bottomMargin
        }
    }
}

extension UILayoutGuide: Anchorable {
    public func anchor(from edge: UIView.HorizontalEdge) -> NSLayoutXAxisAnchor {
        switch edge {
            case .left: return leftAnchor
            case .leading: return leadingAnchor
            case .right: return rightAnchor
            case .trailing: return trailingAnchor
        }
    }
    
    public func anchor(from edge: UIView.VerticalEdge) -> NSLayoutYAxisAnchor {
        switch edge {
            case .top: return topAnchor
            case .bottom: return bottomAnchor
        }
    }
}

public extension NSLayoutConstraint {
    @discardableResult
    func setting(isActive: Bool) -> NSLayoutConstraint {
        self.isActive = isActive
        return self
    }
    
    @discardableResult
    func setting(priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}

public extension Anchorable {
    @discardableResult
    func pin(_ constraineeEdge: UIView.HorizontalEdge, to constrainerEdge: UIView.HorizontalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        (self as? UIView)?.translatesAutoresizingMaskIntoConstraints = false
        
        return anchor(from: constraineeEdge)
            .constraint(
                equalTo: anchorable.anchor(from: constrainerEdge),
                constant: inset
            )
            .setting(isActive: true)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.HorizontalEdge, greaterThanOrEqualTo constrainerEdge: UIView.HorizontalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        (self as? UIView)?.translatesAutoresizingMaskIntoConstraints = false
        
        return anchor(from: constraineeEdge)
            .constraint(
                greaterThanOrEqualTo: anchorable.anchor(from: constrainerEdge),
                constant: inset
            )
            .setting(isActive: true)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.HorizontalEdge, lessThanOrEqualTo constrainerEdge: UIView.HorizontalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        (self as? UIView)?.translatesAutoresizingMaskIntoConstraints = false
        
        return anchor(from: constraineeEdge)
            .constraint(
                lessThanOrEqualTo: anchorable.anchor(from: constrainerEdge),
                constant: inset
            )
            .setting(isActive: true)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.VerticalEdge, to constrainerEdge: UIView.VerticalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        (self as? UIView)?.translatesAutoresizingMaskIntoConstraints = false
        
        return anchor(from: constraineeEdge)
            .constraint(
                equalTo: anchorable.anchor(from: constrainerEdge),
                constant: inset
            )
            .setting(isActive: true)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.VerticalEdge, greaterThanOrEqualTo constrainerEdge: UIView.VerticalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        (self as? UIView)?.translatesAutoresizingMaskIntoConstraints = false
        
        return anchor(from: constraineeEdge)
            .constraint(
                greaterThanOrEqualTo: anchorable.anchor(from: constrainerEdge),
                constant: inset
            )
            .setting(isActive: true)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.VerticalEdge, lessThanOrEqualTo constrainerEdge: UIView.VerticalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        (self as? UIView)?.translatesAutoresizingMaskIntoConstraints = false
        
        return anchor(from: constraineeEdge)
            .constraint(
                lessThanOrEqualTo: anchorable.anchor(from: constrainerEdge),
                constant: inset
            )
            .setting(isActive: true)
    }
}

// MARK: - View extensions

public extension UIView {
    func pin(_ edges: [ConstraintUtilitiesEdge], to view: UIView) {
        edges.forEach {
            switch $0 {
                case let edge as HorizontalEdge: pin(edge, to: edge, of: view)
                case let edge as VerticalEdge: pin(edge, to: edge, of: view)
                default: break
            }
        }
    }
    
    func pin(to view: UIView) {
        [ HorizontalEdge.leading, HorizontalEdge.trailing ].forEach { pin($0, to: $0, of: view) }
        [ VerticalEdge.top, VerticalEdge.bottom ].forEach { pin($0, to: $0, of: view) }
    }
    
    func pin(to view: UIView, withInset inset: CGFloat) {
        pin(.leading, to: .leading, of: view, withInset: inset)
        pin(.top, to: .top, of: view, withInset: inset)
        view.pin(.trailing, to: .trailing, of: self, withInset: inset)
        view.pin(.bottom, to: .bottom, of: self, withInset: inset)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.HorizontalEdge, toMargin constrainerMargin: UIView.HorizontalMargin, of constrainerView: UIView, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        
        return NSLayoutConstraint(
            item: self,
            attribute: attribute(from: constraineeEdge),
            relatedBy: .equal,
            toItem: constrainerView,
            attribute: constrainerView.attribute(from: constrainerMargin),
            multiplier: 1,
            constant: inset
        )
        .setting(isActive: true)
    }
    
    @discardableResult
    func pin(_ constraineeEdge: UIView.VerticalEdge, toMargin constrainerMargin: UIView.VerticalMargin, of constrainerView: UIView, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        
        return NSLayoutConstraint(
            item: self,
            attribute: attribute(from: constraineeEdge),
            relatedBy: .equal,
            toItem: constrainerView,
            attribute: constrainerView.attribute(from: constrainerMargin),
            multiplier: 1,
            constant: inset
        )
        .setting(isActive: true)
    }
    
    func pin(toMarginsOf view: UIView) {
        pin(.top, toMargin: .top, of: view)
        pin(.leading, toMargin: .leading, of: view)
        pin(.trailing, toMargin: .trailing, of: view)
        pin(.bottom, toMargin: .bottom, of: view)
    }
    
    @discardableResult
    func center(_ direction: Direction, in view: UIView, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let constraint: NSLayoutConstraint = {
            switch direction {
            case .horizontal: return centerXAnchor.constraint(equalTo: view.centerXAnchor, constant: inset)
            case .vertical: return centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: inset)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    func center(in view: UIView) {
        center(.horizontal, in: view)
        center(.vertical, in: view)
    }
    
    @discardableResult
    func center(_ direction: VerticalDirection, against constrainerEdge: UIView.VerticalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        
        return centerYAnchor
            .constraint(equalTo: anchorable.anchor(from: constrainerEdge), constant: inset)
            .setting(isActive: true)
    }
    
    @discardableResult
    func center(_ direction: HorizontalDirection, against constrainerEdge: UIView.HorizontalEdge, of anchorable: Anchorable, withInset inset: CGFloat = 0) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        
        return centerXAnchor
            .constraint(equalTo: anchorable.anchor(from: constrainerEdge), constant: inset)
            .setting(isActive: true)
    }
    
    @discardableResult
    func set(_ dimension: Dimension, to size: CGFloat) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let constraint: NSLayoutConstraint = {
            switch dimension {
            case .width: return widthAnchor.constraint(equalToConstant: size)
            case .height: return heightAnchor.constraint(equalToConstant: size)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    @discardableResult
    func set(_ dimension: Dimension, to otherDimension: Dimension, of view: UIView, withOffset offset: CGFloat = 0, multiplier: CGFloat = 1) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let otherAnchor: NSLayoutDimension = {
            switch otherDimension {
                case .width: return view.widthAnchor
                case .height: return view.heightAnchor
            }
        }()
        let constraint: NSLayoutConstraint = {
            switch dimension {
                case .width: return widthAnchor.constraint(equalTo: otherAnchor, multiplier: multiplier, constant: offset)
                case .height: return heightAnchor.constraint(equalTo: otherAnchor, multiplier: multiplier, constant: offset)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    @discardableResult
    func set(_ dimension: Dimension, greaterThanOrEqualTo size: CGFloat) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let constraint: NSLayoutConstraint = {
            switch dimension {
            case .width: return widthAnchor.constraint(greaterThanOrEqualToConstant: size)
            case .height: return heightAnchor.constraint(greaterThanOrEqualToConstant: size)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    @discardableResult
    func set(_ dimension: Dimension, greaterThanOrEqualTo otherDimension: Dimension, of view: UIView, withOffset offset: CGFloat = 0, multiplier: CGFloat = 1) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let otherAnchor: NSLayoutDimension = {
            switch otherDimension {
                case .width: return view.widthAnchor
                case .height: return view.heightAnchor
            }
        }()
        let constraint: NSLayoutConstraint = {
            switch dimension {
            case .width: return widthAnchor.constraint(greaterThanOrEqualTo: otherAnchor, multiplier: multiplier, constant: offset)
            case .height: return heightAnchor.constraint(greaterThanOrEqualTo: otherAnchor, multiplier: multiplier, constant: offset)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    @discardableResult
    func set(_ dimension: Dimension, lessThanOrEqualTo size: CGFloat) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let constraint: NSLayoutConstraint = {
            switch dimension {
            case .width: return widthAnchor.constraint(lessThanOrEqualToConstant: size)
            case .height: return heightAnchor.constraint(lessThanOrEqualToConstant: size)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    @discardableResult
    func set(_ dimension: Dimension, lessThanOrEqualTo otherDimension: Dimension, of view: UIView, withOffset offset: CGFloat = 0, multiplier: CGFloat = 1) -> NSLayoutConstraint {
        translatesAutoresizingMaskIntoConstraints = false
        let otherAnchor: NSLayoutDimension = {
            switch otherDimension {
                case .width: return view.widthAnchor
                case .height: return view.heightAnchor
            }
        }()
        let constraint: NSLayoutConstraint = {
            switch dimension {
            case .width: return widthAnchor.constraint(lessThanOrEqualTo: otherAnchor, multiplier: multiplier, constant: offset)
            case .height: return heightAnchor.constraint(lessThanOrEqualTo: otherAnchor, multiplier: multiplier, constant: offset)
            }
        }()
        constraint.isActive = true
        return constraint
    }
    
    func setContentHugging(to priority: UILayoutPriority) {
        setContentHuggingPriority(priority, for: .vertical)
        setContentHuggingPriority(priority, for: .horizontal)
    }
    
    func setContentHugging(_ direction: Direction, to priority: UILayoutPriority) {
        switch direction {
            case .vertical: setContentHuggingPriority(priority, for: .vertical)
            case .horizontal: setContentHuggingPriority(priority, for: .horizontal)
        }
    }
    
    func setCompressionResistance(to priority: UILayoutPriority) {
        setContentCompressionResistancePriority(priority, for: .vertical)
        setContentCompressionResistancePriority(priority, for: .horizontal)
    }
    
    func setCompressionResistance(_ direction: Direction, to priority: UILayoutPriority) {
        switch direction {
            case .vertical: setContentCompressionResistancePriority(priority, for: .vertical)
            case .horizontal: setContentCompressionResistancePriority(priority, for: .horizontal)
        }
    }
}
