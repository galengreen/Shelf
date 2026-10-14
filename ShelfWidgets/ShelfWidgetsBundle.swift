import SwiftUI
import WidgetKit

@main
struct ShelfWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        StreakWidget()
        ActivityWidget()
        NowPlayingLiveActivity()
        PlaybackControl()
        SkipBackControl()
        SleepTimerControl()
    }
}
