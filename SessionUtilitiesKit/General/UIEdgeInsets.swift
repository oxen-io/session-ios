import UIKit

extension UIEdgeInsets {

    public init(uniform value: CGFloat) {
        self.init(top: value, left: value, bottom: value, right: value)
    }
    
    public init(top: CGFloat, leading: CGFloat, bottom: CGFloat, trailing: CGFloat) {
        self.init(
            top: top,
            left: (Singleton.hasAppContext && Singleton.appContext.isRTL ? trailing : leading),
            bottom: bottom,
            right: (Singleton.hasAppContext && Singleton.appContext.isRTL ? leading : trailing)
        )
    }
}
