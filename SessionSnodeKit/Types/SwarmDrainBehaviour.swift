// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public enum SwarmDrainBehaviour {
    case alwaysRandom
    case limitedReuse(
        count: UInt,
        targetSnode: Snode?,
        targetUseCount: Int,
        usedSnodes: Set<Snode>,
        swarmHash: Int
    )
    
    public static func limitedReuse(count: UInt) -> SwarmDrainBehaviour {
        guard count > 1 else { return .alwaysRandom }
        
        return .limitedReuse(count: count, targetSnode: nil, targetUseCount: 0, usedSnodes: [], swarmHash: 0)
    }
    
    // MARK: - Convenience
    
    func use(snode: Snode, from swarm: Set<Snode>) -> SwarmDrainBehaviour {
        switch self {
            case .alwaysRandom: return .alwaysRandom
            case .limitedReuse(let count, let targetSnode, let targetUseCount, let usedSnodes, _):
                // If we are using a new snode then reset everything
                guard targetSnode == snode else {
                    return .limitedReuse(
                        count: count,
                        targetSnode: snode,
                        targetUseCount: 1,
                        usedSnodes: usedSnodes.inserting(snode),
                        swarmHash: swarm.hashValue
                    )
                }
                
                // Increment the use count and clear the target if it's been used too many times
                let updatedUseCount: Int = (targetUseCount + 1)
                
                return .limitedReuse(
                    count: count,
                    targetSnode: (updatedUseCount < count ? snode : nil),
                    targetUseCount: updatedUseCount,
                    usedSnodes: usedSnodes,
                    swarmHash: swarm.hashValue
                )
        }
    }
    
    public func clearTargetSnode() -> SwarmDrainBehaviour {
        switch self {
            case .alwaysRandom: return .alwaysRandom
            case .limitedReuse(let count, _, _, let usedSnodes, let swarmHash):
                return .limitedReuse(
                    count: count,
                    targetSnode: nil,
                    targetUseCount: 0,
                    usedSnodes: usedSnodes,
                    swarmHash: swarmHash
                )
        }
    }
    
    public func reset() -> SwarmDrainBehaviour {
        switch self {
            case .alwaysRandom: return .alwaysRandom
            case .limitedReuse(let count, _, _, _, _):
                return .limitedReuse(
                    count: count,
                    targetSnode: nil,
                    targetUseCount: 0,
                    usedSnodes: [],
                    swarmHash: 0
                )
        }
    }
}

// MARK: - Convenience

public extension Atomic where Value == SwarmDrainBehaviour {
    static var alwaysRandom: Atomic<SwarmDrainBehaviour> { Atomic(.alwaysRandom) }
}
