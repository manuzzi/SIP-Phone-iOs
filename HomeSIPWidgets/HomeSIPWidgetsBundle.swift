import WidgetKit
import SwiftUI

@main
struct HomeSIPWidgetsBundle: WidgetBundle {
    var body: some Widget {
        HomeSIPStatusWidget()
        if #available(iOS 18.0, *) {
            HomeSIPStatusControl()
        }
    }
}
