// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public typealias LogLevel = SessionUtil.config_log_level

public enum LibSession {
    public static let logLevel: LogLevel = LOG_LEVEL_INFO
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}
