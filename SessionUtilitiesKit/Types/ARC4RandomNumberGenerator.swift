// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// Note: This was taken from TensorFlow's Random:
// https://github.com/apple/swift/blob/bc8f9e61d333b8f7a625f74d48ef0b554726e349/stdlib/public/TensorFlow/Random.swift
//
// the complex approach is needed due to an issue with Swift's randomElement(using:)
// generation (see https://stackoverflow.com/a/64897775 for more info)

import Foundation

public struct ARC4RandomNumberGenerator: RandomNumberGenerator {
    var state: [UInt8] = Array(0...255)
    var iPos: UInt8 = 0
    var jPos: UInt8 = 0
    
    public init<T: BinaryInteger>(seed: T) {
        self.init(
            seed: (0..<(UInt64.bitWidth / UInt64.bitWidth)).map { index in
                UInt8(truncatingIfNeeded: seed >> (UInt8.bitWidth * index))
            }
        )
    }
    
    public init(seed: [UInt8]) {
        precondition(seed.count > 0, "Length of seed must be positive")
        precondition(seed.count <= 256, "Length of seed must be at most 256")
        
        // Note: Have to use a for loop instead of a 'forEach' otherwise
        // it doesn't work properly (not sure why...)
        var j: UInt8 = 0
        for i: UInt8 in 0...255 {
          j &+= S(i) &+ seed[Int(i) % seed.count]
          swapAt(i, j)
        }
    }
    
    /// Produce the next random UInt64 from the stream, and advance the internal state
    public mutating func next() -> UInt64 {
        // Note: Have to use a for loop instead of a 'forEach' otherwise
        // it doesn't work properly (not sure why...)
        var result: UInt64 = 0
        for _ in 0..<UInt64.bitWidth / UInt8.bitWidth {
          result <<= UInt8.bitWidth
          result += UInt64(nextByte())
        }
        
        return result
    }
    
    /// Helper to access the state
    private func S(_ index: UInt8) -> UInt8 {
        return state[Int(index)]
    }
    
    /// Helper to swap elements of the state
    private mutating func swapAt(_ i: UInt8, _ j: UInt8) {
        state.swapAt(Int(i), Int(j))
    }

    /// Generates the next byte in the keystream.
    private mutating func nextByte() -> UInt8 {
        iPos &+= 1
        jPos &+= S(iPos)
        swapAt(iPos, jPos)
        return S(S(iPos) &+ S(jPos))
    }
}

public extension ARC4RandomNumberGenerator {
    mutating func nextBytes(count: Int) -> [UInt8] {
        (0..<count).map { _ in nextByte() }
    }
}
