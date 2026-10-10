import SwiftUI
import WidgetKit

/// "Talk to Dave" on the home screen and lock screen: tapping it opens Dave, already listening.
@main
struct DaveWidgets: WidgetBundle {
    var body: some Widget { TalkWidget() }
}

struct TalkWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "talk", provider: Always()) { _ in
            TalkView().widgetURL(URL(string: "dave-iphone://talk"))
        }
        .configurationDisplayName("Talk to Dave")
        .description("Tap to talk to Dave right away.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

/// The widget never changes: one entry, forever.
struct Always: TimelineProvider {
    struct Entry: TimelineEntry { let date = Date() }
    func placeholder(in context: Context) -> Entry { Entry() }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) { completion(Timeline(entries: [Entry()], policy: .never)) }
}

/// Dave's Aurora colours (the widget can't see the app's chosen theme).
private let purple = Color(red: 0x96 / 255, green: 0x46 / 255, blue: 0xFF / 255)
private let pink = Color(red: 0xDC / 255, green: 0x50 / 255, blue: 0xE6 / 255)
private let cyan = Color(red: 0x00 / 255, green: 0xD2 / 255, blue: 0xFF / 255)
private let deep = Color(red: 0x10 / 255, green: 0x0A / 255, blue: 0x26 / 255)

struct TalkView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "waveform").font(.title2.bold())
            }
            .widgetBackground(Color.clear)
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "waveform").font(.title3.bold())
                VStack(alignment: .leading) {
                    Text("Dave").font(.headline)
                    Text("Tap to talk").font(.caption)
                }
            }
            .widgetBackground(Color.clear)
        default:
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(AngularGradient(colors: [purple, pink, cyan, purple], center: .center)).blur(radius: 10).opacity(0.8)
                    Circle().fill(AngularGradient(colors: [purple, pink, cyan, purple], center: .center))
                        .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.5), .clear], center: UnitPoint(x: 0.35, y: 0.3), startRadius: 0, endRadius: 30)))
                    Image(systemName: "waveform").font(.title2.bold()).foregroundStyle(.white)
                }
                .frame(width: 64, height: 64)
                Text("Talk to Dave").font(.subheadline.bold()).foregroundStyle(.white)
            }
            .widgetBackground(deep)
        }
    }
}

private extension View {
    /// iOS 17 wants the background through containerBackground; iOS 16 just as a background.
    @ViewBuilder func widgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) { containerBackground(color, for: .widget) }
        else { background(color) }
    }
}
