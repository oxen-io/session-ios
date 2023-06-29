// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

open class SSKDependencies: Dependencies {
    public var _onionApi: Atomic<OnionRequestAPIType.Type?>
    public var onionApi: OnionRequestAPIType.Type {
        get { Dependencies.getValueSettingIfNull(&_onionApi) { OnionRequestAPI.self } }
        set { _onionApi.mutate { $0 = newValue } }
    }
    
    // MARK: - Initialization
    
    public init(
        subscribeQueue: DispatchQueue? = nil,
        receiveQueue: DispatchQueue? = nil,
        onionApi: OnionRequestAPIType.Type? = nil,
        generalCache: MutableGeneralCacheType? = nil,
        storage: Storage? = nil,
        scheduler: ValueObservationScheduler? = nil,
        standardUserDefaults: UserDefaultsType? = nil,
        date: Date? = nil
    ) {
        _onionApi = Atomic(onionApi)
        
        super.init(
            subscribeQueue: subscribeQueue,
            receiveQueue: receiveQueue,
            generalCache: generalCache,
            storage: storage,
            scheduler: scheduler,
            standardUserDefaults: standardUserDefaults,
            date: date
        )
    }
}
