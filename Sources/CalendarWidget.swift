import SwiftUI
import EventKit

final class CalendarController: ObservableObject {
    private let store = EKEventStore()
    @Published var events: [EKEvent] = []
    @Published var status: String = "Loading…"

    func requestAndLoad() {
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted { self.load() }
                else { self.status = "Enable calendar in System Settings ▸ Privacy" }
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
            }
        }
    }
}

struct CalendarPanel: View {
    @ObservedObject var controller: CalendarController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(Date(), format: .dateTime.weekday(.wide).month().day())
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                Button { controller.load() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10.5))
                }
                .buttonStyle(.plain)
                .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            if controller.events.isEmpty {
                Spacer()
                Text(controller.status)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        // id: \.self (EKEvent is a class, so this is identity).
                        // eventIdentifier can be nil AND duplicates across
                        // same-day recurrences, which made SwiftUI drop rows.
                        ForEach(controller.events, id: \.self) { ev in
                            EventRow(event: ev)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .background(Color.black)
    }
}

private struct EventRow: View {
    let event: EKEvent
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                // `calendar` is another EventKit IUO that can be nil.
                .fill(Color(event.calendar?.cgColor ?? CGColor(gray: 0.6, alpha: 1)))
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "(no title)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(timeText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private var timeText: String {
        if event.isAllDay { return "All day" }
        let f = Date.FormatStyle.dateTime.hour().minute()
        guard let start = event.startDate as Date?, let end = event.endDate as Date? else { return "" }
        return "\(start.formatted(f)) – \(end.formatted(f))"
    }
}
