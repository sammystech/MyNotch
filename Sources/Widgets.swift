import Foundation

// The widget registry. To add a new widget:
//   1. Add a case here with a title + SF Symbol.
//   2. Add a matching branch in NotchRootView's `switch state.selected`.
//   3. (Optional) create a controller + panel view for it.
enum WidgetKind: String, CaseIterable, Identifiable {
    /// Tabs shown around the notch. Settings is reached by its own gear button.
    static var tabs: [WidgetKind] { allCases.filter { $0 != .settings } }

    case mirror
    case music
    case shelf
    case calendar
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendar: return "Calendar"
        case .mirror:   return "Mirror"
        case .music:    return "Music"
        case .shelf:    return "Shelf"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: return "calendar"
        case .mirror:   return "camera"
        case .music:    return "music.note"
        case .shelf:    return "tray.full"
        case .settings: return "gearshape.fill"
        }
    }
}
