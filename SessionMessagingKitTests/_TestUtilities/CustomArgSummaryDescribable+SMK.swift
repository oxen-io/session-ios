// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit
import SessionUtilitiesKit

extension Job: CustomArgSummaryDescribable {
    var customArgSummaryDescribable: String? {
        switch variant {
            case .attachmentUpload:
                guard
                    let detailsData: Data = details,
                    let details: AttachmentUploadJob.Details = try? JSONDecoder()
                        .decode(AttachmentUploadJob.Details.self, from: detailsData)
                else { return nil }

                let stringParts: [String] = String(reflecting: self).components(separatedBy: "details: Optional(")

                guard stringParts.count > 1 else { return nil }

                let stringSuffix: [String] = stringParts[1].components(separatedBy: " bytes)")
                guard stringSuffix.count > 1 else { return nil }

                return (stringParts[0] + String(reflecting: details) + stringSuffix[1])
                
            default:
                guard
                    let detailsData: Data = details,
                    let detailsString: String = String(data: detailsData, encoding: .utf8)
                else { return nil }
                
                let stringParts: [String] = String(reflecting: self).components(separatedBy: "details: Optional(")
                
                guard stringParts.count > 1 else { return nil }
                
                let stringSuffix: [String] = stringParts[1].components(separatedBy: " bytes)")
                guard stringSuffix.count > 1 else { return nil }
                
                return (stringParts[0] + detailsString + stringSuffix[1])
        }
    }
}
