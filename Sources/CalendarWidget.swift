import SwiftUI
import EventKit

final class CalendarController: ObservableObject {
    private let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var status: String = "Loading…"
    @Published var denied = false

    func requestAndLoad() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.denied = !granted
                if granted { self.load() }
                else { self.status = "Calendar access is off" }
            }
        }
    }

    func load() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        // events(matching:) is a blocking SQLite + XPC query into calendaraccessd
        // — routinely 200-800ms with CalDAV/Exchange accounts, which visibly
        // stalled the panel when run on the main thread.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // startDate/endDate are implicitly-unwrapped optionals in EventKit
            // and CAN be nil for synced/detached recurrence instances — sorting
            // or formatting those crashes. Drop them defensively.
            let found = self.store.events(matching: predicate)
                .filter { $0.startDate != nil && $0.endDate != nil }
                .sorted { $0.startDate < $1.startDate }
            DispatchQueue.main.async {
                self.events = found
                self.status = found.isEmpty ? "No events today" : ""
                self.denied = false
            }
        }
    }
}

// Apple's Calendar widget, in the dark: red weekday, big date and a week
// strip on the left; today's agenda on the right.
struct CalendarPanel: View {
    @ObservedObject var controller: CalendarController
    private let red = Color(red: 1, green: 0.27, blue: 0.23)

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            dateColumn
                .frame(width: 112, alignment: .leading)
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 0.5)
                .padding(.vertical, 6)
            agenda
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.black)
    }

    private var dateColumn: some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 0) {
            Text(now.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
                .foregroundColor(red)
            Text(now.formatted(.dateTime.day()))
                .font(.system(size: 40, weight: .regular))
                .padding(.top, -2)
            Text(now.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            Spacer(minLength: 6)
            weekStrip(now)
        }
    }

    private func weekStrip(_ today: Date) -> some View {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: start) }
        return HStack(spacing: 0) {
            ForEach(days, id: \.self) { d in
                let isToday = cal.isDate(d, inSameDayAs: today)
                VStack(spacing: 3) {
                    Text(d.formatted(.dateTime.weekday(.narrow)))
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.35))
                    Text(d.formatted(.dateTime.day()))
                        .font(.system(size: 9, weight: isToday ? .bold : .medium).monospacedDigit())
                        .foregroundColor(isToday ? .white : .white.opacity(0.7))
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(isToday ? red : .clear))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var agenda: some View {
        if controller.events.isEmpty {
            VStack(spacing: 9) {
                Image(systemName: controller.denied ? "calendar.badge.exclamationmark" : "checkmark.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 38, height: 38)
                    .darkGlass(Circle(), intensity: 0.7)
                Text(controller.denied ? "Calendar access is off" : "No events today")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                if controller.denied {
                    GlassPillButton(title: "Open Settings", symbol: "gearshape.fill") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                } else {
                    Text("Enjoy the free time")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("TODAY")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(0.6)
                        .foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Button { controller.load() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white.opacity(0.35))
                            .frame(width: 18, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                }
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 5) {
                        // id: \.self (EKEvent is a class, so this is identity).
                        // eventIdentifier can be nil AND duplicates across
                        // same-day recurrences, which made SwiftUI drop rows.
                        ForEach(controller.events, id: \.self) { ev in
                            EventRow(event: ev)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct EventRow: View {
    let event: EKEvent

    var body: some View {
        let now = Date()
        let start = event.startDate as Date?, end = event.endDate as Date?
        let isNow = !event.isAllDay && (start.map { $0 <= now } ?? false) && (end.map { $0 > now } ?? false)
        let isPast = !event.isAllDay && (end.map { $0 <= now } ?? false)
        // `calendar` is another EventKit IUO that can be nil.
        let color = Color(event.calendar?.cgColor ?? CGColor(gray: 0.6, alpha: 1))

        return HStack(spacing: 8) {
            Capsule().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title ?? "(no title)")
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if isNow {
                        Text("NOW")
                            .font(.system(size: 7.5, weight: .heavy))
                            .foregroundColor(.black)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(color))
                    }
                    Text(timeText)
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 5).padding(.leading, 5).padding(.trailing, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(isNow ? 0.2 : 0.1))
        )
        .opacity(isPast ? 0.45 : 1)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = Date.FormatStyle.dateTime.hour().minute()
        guard let start = event.startDate as Date?, let end = event.endDate as Date? else { return "" }
        return "\(start.formatted(f)) – \(end.formatted(f))"
    }
}
