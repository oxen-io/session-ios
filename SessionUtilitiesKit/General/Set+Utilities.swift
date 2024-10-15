// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Set {
    mutating func insert(contentsOf value: Set<Element>?) {
        guard let value: Set<Element> = value else { return }
        
        value.forEach { self.insert($0) }
    }
    
    func inserting(_ value: Element?) -> Set<Element> {
        guard let value: Element = value else { return self }
        
        var updatedSet: Set<Element> = self
        updatedSet.insert(value)
        
        return updatedSet
    }
    
    func inserting(contentsOf value: Set<Element>?) -> Set<Element> {
        guard let value: Set<Element> = value else { return self }
        
        var updatedSet: Set<Element> = self
        value.forEach { updatedSet.insert($0) }
        
        return updatedSet
    }
    
    func removing(_ value: Element?) -> Set<Element> {
        guard let value: Element = value else { return self }
        
        var updatedSet: Set<Element> = self
        updatedSet.remove(value)
        
        return updatedSet
    }
    
    func removing(contentsOf value: Set<Element>?) -> Set<Element> {
        guard let value: Set<Element> = value else { return self }
        
        var updatedSet: Set<Element> = self
        value.forEach { updatedSet.remove($0) }
        
        return updatedSet
    }
    
    mutating func popRandomElement() -> Element? {
        guard let value: Element = randomElement() else { return nil }
        
        self.remove(value)
        return value
    }
    
    func chunked(by chunkSize: Int) -> [Set<Element>] {
        return Array(self).chunked(by: chunkSize).map { Set($0) }
    }
}
