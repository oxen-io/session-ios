// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockUserDefaults: Mock<UserDefaultsType>, UserDefaultsType {
    var allKeys: [String] { mock() }
    
    func object(forKey defaultName: String) -> Any? { return mock(args: [defaultName]) }
    func string(forKey defaultName: String) -> String? { return mock(args: [defaultName]) }
    func array(forKey defaultName: String) -> [Any]? { return mock(args: [defaultName]) }
    func dictionary(forKey defaultName: String) -> [String: Any]? { return mock(args: [defaultName]) }
    func data(forKey defaultName: String) -> Data? { return mock(args: [defaultName]) }
    func stringArray(forKey defaultName: String) -> [String]? { return mock(args: [defaultName]) }
    func integer(forKey defaultName: String) -> Int { return (mock(args: [defaultName]) ?? 0) }
    func float(forKey defaultName: String) -> Float { return (mock(args: [defaultName]) ?? 0) }
    func double(forKey defaultName: String) -> Double { return (mock(args: [defaultName]) ?? 0) }
    func bool(forKey defaultName: String) -> Bool { return (mock(args: [defaultName]) ?? false) }
    func url(forKey defaultName: String) -> URL? { return mock(args: [defaultName]) }

    func set(_ value: Any?, forKey defaultName: String) { mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Int, forKey defaultName: String) { mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Float, forKey defaultName: String) { mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Double, forKey defaultName: String) { mockNoReturn(args: [value, defaultName]) }
    func set(_ value: Bool, forKey defaultName: String) { mockNoReturn(args: [value, defaultName]) }
    func set(_ url: URL?, forKey defaultName: String) { mockNoReturn(args: [url, defaultName]) }
    
    func removeAll() { mockNoReturn() }
}
