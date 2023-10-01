// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension SessionUtil {
    typealias UserConfigInitialiser = (
        UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>?,    // conf
        UnsafePointer<UInt8>?,                                          // ed25519_secretkey
        UnsafePointer<UInt8>?,                                          // dump
        Int,                                                            // dumplen
        UnsafeMutablePointer<CChar>?                                    // error
    ) -> Int32
    typealias GroupConfigInitialiser = (
        UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>?,    // conf
        UnsafePointer<UInt8>?,                                          // ed25519_pubkey
        UnsafePointer<UInt8>?,                                          // ed25519_secretkey
        UnsafePointer<UInt8>?,                                          // dump
        Int,                                                            // dumplen
        UnsafeMutablePointer<CChar>?                                    // error
    ) -> Int32
    typealias ConfigSizeInfo = (UnsafePointer<config_object>?) -> Int
    
    // MARK: - Config
    
    enum Config {
        case invalid
        case object(UnsafeMutablePointer<config_object>)
        case groupKeys(
            UnsafeMutablePointer<config_group_keys>,
            info: UnsafeMutablePointer<config_object>,
            members: UnsafeMutablePointer<config_object>
        )
        
        // MARK: - Variables
        
        var needsPush: Bool {
            switch self {
                case .invalid: return false
                case .object(let conf): return config_needs_push(conf)
                
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>? = nil
                    var pushResultLen: Int = 0
                    
                    return groups_keys_pending_config(conf, &pushResult, &pushResultLen)
            }
        }
        
        var needsDump: Bool {
            switch self {
                case .invalid: return false
                case .object(let conf): return config_needs_dump(conf)
                case .groupKeys(let conf, _, _): return groups_keys_needs_dump(conf)
            }
        }
        
        var lastError: String {
            switch self {
                case .invalid: return "Invalid"
                case .object(let conf): return String(cString: conf.pointee.last_error)
                case .groupKeys(let conf, _, _): return String(cString: conf.pointee.last_error)
            }
        }
        
        // MARK: - Functions
        
        func addingLogger() -> Config {
            switch self {
                case .object(let conf):
                    config_set_logger(
                        conf,
                        { logLevel, messagePtr, _ in
                            guard
                                logLevel.rawValue >= SessionUtil.logLevel.rawValue,
                                let messagePtr = messagePtr
                            else { return }

                            let message: String = String(cString: messagePtr)
                            print("[SessionUtil] \(message)")
                        },
                        nil
                    )
                
                default: break
            }
            
            return self
        }
        
        func push(variant: ConfigDump.Variant) throws -> SessionUtil.PushData {
            switch self {
                case .invalid: throw SessionUtilError.invalidConfigObject
                case .object(let conf):
                    var cPushData: UnsafeMutablePointer<config_push_data>!
                    
                    try CExceptionHelper.performSafely {
                        cPushData = config_push(conf)
                    }
                    
                    let pushData: Data = Data(
                        bytes: cPushData.pointee.config,
                        count: cPushData.pointee.config_len
                    )
                    let obsoleteHashes: [String] = [String](
                        pointer: cPushData.pointee.obsolete,
                        count: cPushData.pointee.obsolete_len,
                        defaultValue: []
                    )
                    let seqNo: Int64 = cPushData.pointee.seqno
                    cPushData.deallocate()
                    
                    return SessionUtil.PushData(
                        data: pushData,
                        seqNo: seqNo,
                        variant: variant,
                        obsoleteHashes: obsoleteHashes
                    )
                    
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>!
                    var pushResultLen: Int = 0
                    
                    guard groups_keys_pending_config(conf, &pushResult, &pushResultLen) else {
                        return SessionUtil.PushData(
                            data: Data(),
                            seqNo: 0,
                            variant: variant,
                            obsoleteHashes: []
                        )
                    }
                    
                    return SessionUtil.PushData(
                        data: Data(bytes: pushResult, count: pushResultLen),
                        seqNo: 0,
                        variant: variant,
                        obsoleteHashes: []
                    )
            }
        }
        
        func confirmPushed(
            seqNo: Int64,
            hash: String
        ) {
            var cHash: [CChar] = hash.cArray.nullTerminated()
            
            switch self {
                case .invalid: return
                case .object(let conf): return config_confirm_pushed(conf, seqNo, &cHash)
                case .groupKeys: return // No need to do anything here
            }
        }
        
        func dump() throws -> Data? {
            var dumpResult: UnsafeMutablePointer<UInt8>? = nil
            var dumpResultLen: Int = 0
            
            try CExceptionHelper.performSafely {
                switch self {
                    case .invalid: return
                    case .object(let conf): config_dump(conf, &dumpResult, &dumpResultLen)
                    case .groupKeys(let conf, _, _): groups_keys_dump(conf, &dumpResult, &dumpResultLen)
                }
            }
            
            guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
            
            let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
            dumpResult.deallocate()
            
            return dumpData
        }
        
        func currentHashes() -> [String] {
            switch self {
                case .invalid: return []
                case .object(let conf):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = config_current_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        pointer: hashList.pointee.value,
                        count: hashList.pointee.len,
                        defaultValue: []
                    )
                    hashList.deallocate()
                    
                    return result
                    
                case .groupKeys(let conf, _, _):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = groups_keys_current_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        pointer: hashList.pointee.value,
                        count: hashList.pointee.len,
                        defaultValue: []
                    )
                    hashList.deallocate()
                    
                    return result
            }
        }
        
        func merge(_ messages: [ConfigMessageReceiveJob.Details.MessageInfo]) throws -> Int64? {
            switch self {
                case .invalid: throw SessionUtilError.invalidConfigObject
                case .object(let conf):
                    var mergeHashes: [UnsafePointer<CChar>?] = messages
                        .map { message in message.serverHash.cArray.nullTerminated() }
                        .unsafeCopy()
                    var mergeData: [UnsafePointer<UInt8>?] = messages
                        .map { message -> [UInt8] in message.data.bytes }
                        .unsafeCopy()
                    var mergeSize: [Int] = messages.map { $0.data.count }
                    try CExceptionHelper.performSafely {
                        config_merge(
                            conf,
                            &mergeHashes,
                            &mergeData,
                            &mergeSize,
                            messages.count
                        )
                    }
                    mergeHashes.forEach { $0?.deallocate() }
                    mergeData.forEach { $0?.deallocate() }
                    
                    // Get the list of hashes from the config (to determine which were successful)
                    let currentHashes: Set<String> = currentHashes().asSet()
                    
                    return messages
                        .filter { currentHashes.contains($0.serverHash) }
                        .map { $0.serverTimestampMs }
                        .sorted()
                        .last
                    
                case .groupKeys(let conf, let infoConf, let membersConf):
                    return messages
                        .map { message -> (Bool, Int64) in
                            var data: [UInt8] = Array(message.data)
                            var messageHash: [CChar] = message.serverHash.cArray.nullTerminated()
                            let result: Bool = groups_keys_load_message(
                                conf,
                                &messageHash,
                                &data,
                                data.count,
                                message.serverTimestampMs,
                                infoConf,
                                membersConf
                            )
                            
                            return (result, message.serverTimestampMs)
                        }
                        .filter { success, _ in success }
                        .map { _, serverTimestampMs in serverTimestampMs }
                        .sorted()
                        .last
            }
        }
        
        func count(for variant: ConfigDump.Variant) -> String {
            var result: String? = nil
            let funcMap: [ConfigDump.Variant: (info: String, size: ConfigSizeInfo)] = [
                .userProfile: ("profile", { _ in 1 }),
                .contacts: ("contacts", contacts_size),
                .userGroups: ("group conversations", user_groups_size),
                .convoInfoVolatile: ("volatile conversations", convo_info_volatile_size),
                .groupInfo: ("group info", { _ in 1 }),
                .groupMembers: ("group members", groups_members_size)
            ]
            
            try? CExceptionHelper.performSafely {
                switch self {
                    case .invalid: return
                    case .object(let conf): result = funcMap[variant].map { "\($0.size(conf)) \($0.info)" }
                    case .groupKeys(let conf, _, _): result = "\(groups_keys_size(conf)) group keys"
                }
            }
            
            return (result ?? "Invalid")
        }
    }
}

// MARK: - PushData

public extension SessionUtil {
    struct PushData {
        let data: Data
        let seqNo: Int64
        let variant: ConfigDump.Variant
        let obsoleteHashes: [String]
    }
}

// MARK: - Optional Convenience

public extension Optional where Wrapped == SessionUtil.Config {
    // MARK: - Variables
    
    var needsPush: Bool {
        switch self {
            case .some(let config): return config.needsPush
            case .none: return false
        }
    }
    
    var needsDump: Bool {
        switch self {
            case .some(let config): return config.needsDump
            case .none: return false
        }
    }
    
    var lastError: String {
        switch self {
            case .some(let config): return config.lastError
            case .none: return "Nil Config"
        }
    }
    
    // MARK: - Functions
    
    func confirmPushed(seqNo: Int64, hash: String) {
        switch self {
            case .some(let config): return config.confirmPushed(seqNo: seqNo, hash: hash)
            case .none: return
        }
    }
    
    func dump() throws -> Data? {
        switch self {
            case .some(let config): return try config.dump()
            case .none: return nil
        }
    }
    
    func currentHashes() -> [String] {
        switch self {
            case .some(let config): return config.currentHashes()
            case .none: return []
        }
    }
}

// MARK: - Atomic Convenience

public extension Atomic where Value == Optional<SessionUtil.Config> {
    var needsPush: Bool { return wrappedValue.needsPush }
    var needsDump: Bool { return wrappedValue.needsDump }
}