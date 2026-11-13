import SwiftUI

struct FocusedAppModelKey: FocusedValueKey {
    typealias Value = AppModel
}

extension FocusedValues {
    var appModel: AppModel? {
        get { self[FocusedAppModelKey.self] }
        set { self[FocusedAppModelKey.self] = newValue }
    }
}
