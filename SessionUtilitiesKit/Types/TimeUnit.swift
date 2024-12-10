// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum TimeUnit: Equatable, CustomStringConvertible {
    case nanoseconds(Double)
    case microseconds(Double)
    case milliseconds(Double)
    case seconds(Double)
    case minutes(Double)
    case hours(Double)
    case days(Double)
    case weeks(Double)
    
    public var timeInterval: TimeInterval {
        switch self {
            case .nanoseconds(let value): return (value * 1e-9)
            case .microseconds(let value): return (value * 1e-6)
            case .milliseconds(let value): return (value * 1e-3)
            case .seconds(let value): return value
            case .minutes(let value): return (value * 60)
            case .hours(let value): return (value * 3600)
            case .days(let value): return (value * 86400)
            case .weeks(let value): return (value * 604800)
        }
    }
    
    var unit: Unit {
        switch self {
            case .nanoseconds: return .nanoseconds
            case .microseconds: return .microseconds
            case .milliseconds: return .milliseconds
            case .seconds: return .seconds
            case .minutes: return .minutes
            case .hours: return .hours
            case .days: return .days
            case .weeks: return .weeks
        }
    }
    
    public var description: String {
        switch self {
            case .nanoseconds(let value): return "\(value)\(unit)"
            case .microseconds(let value): return "\(value)\(unit)"
            case .milliseconds(let value): return "\(value)\(unit)"
            case .seconds(let value): return "\(value)\(unit)"
            case .minutes(let value): return "\(value)\(unit)"
            case .hours(let value): return "\(value)\(unit)"
            case .days(let value): return "\(value)\(unit)"
            case .weeks(let value): return "\(value)\(unit)"
        }
    }
    
    public init(_ other: TimeUnit, unit: Unit, resolution: Int? = nil) {
        let otherSeconds: TimeInterval = other.timeInterval
        let convertedValue: Double = {
            switch unit {
                case .nanoseconds: return (otherSeconds / 1e-9)
                case .microseconds: return (otherSeconds / 1e-6)
                case .milliseconds: return (otherSeconds / 1e-3)
                case .seconds: return (otherSeconds)
                case .minutes: return (otherSeconds / 60)
                case .hours: return (otherSeconds / 3600)
                case .days: return (otherSeconds / 86400)
                case .weeks: return (otherSeconds / 604800)
            }
        }()
        let result: Double = {
            guard let resolution: Int = resolution else { return convertedValue }
            guard resolution > 0 else { return floor(convertedValue) }
            
            let targetResolution: TimeInterval = pow(10, TimeInterval(resolution))
            
            return (floor(convertedValue * targetResolution) / targetResolution)
        }()
        
        switch unit {
            case .nanoseconds: self = .nanoseconds(result)
            case .microseconds: self = .microseconds(result)
            case .milliseconds: self = .milliseconds(result)
            case .seconds: self = .seconds(result)
            case .minutes: self = .minutes(result)
            case .hours: self = .hours(result)
            case .days: self = .days(result)
            case .weeks: self = .weeks(result)
        }
    }
}

// MARK: - TimeUnit.Unit

public extension TimeUnit {
    enum Unit: CustomStringConvertible {
        case nanoseconds
        case microseconds
        case milliseconds
        case seconds
        case minutes
        case hours
        case days
        case weeks
        
        public static var ns: Unit = .nanoseconds
        public static var us: Unit = .microseconds   //µs
        public static var ms: Unit = .milliseconds
        public static var s: Unit = .seconds
        public static var m: Unit = .minutes
        public static var h: Unit = .hours
        public static var d: Unit = .days
        public static var w: Unit = .weeks
        
        public var description: String {
            switch self {
                case .nanoseconds: return "ns"
                case .microseconds: return "µs"
                case .milliseconds: return "ms"
                case .seconds: return "s"
                case .minutes: return "m"
                case .hours: return "h"
                case .days: return "d"
                case .weeks: return "w"
            }
        }
    }
}
