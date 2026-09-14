import SwiftUI
import WidgetKit

@main
struct MangaBakaWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DueThisWeekWidget()
        PickBackUpWidget()
        NextVolumeWidget()
    }
}
