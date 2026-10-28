import SwiftUI

/// View-layer navigation state for the main window's three-pane shell: which screen
/// the center pane shows. Meeting selection itself stays with the history browser
/// (`HistoryView.selection`); selecting a meeting switches the route to `.notes`.
@MainActor
final class MainShellModel: ObservableObject {
    enum Route: Equatable {
        /// The live recording screen (also the idle "new recording" screen).
        case live
        /// The selected meeting(s): note detail, or the bulk panel for a multi-select.
        case notes
        /// People / voiceprints.
        case people
    }

    @Published var route: Route = .live
}

/// Date buckets for the sidebar's meeting list, newest first (Claude-style grouping).
enum MeetingDateGroup: Hashable, Comparable {
    case today, yesterday, previous7Days, previous30Days
    /// Older meetings, grouped by the first day of their month.
    case month(Date)

    init(_ date: Date, now: Date = Date(), calendar: Calendar = .current) {
        let startOfToday = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: startOfToday).day ?? 0
        switch days {
        case ..<1: self = .today
        case 1: self = .yesterday
        case 2..<7: self = .previous7Days
        case 7..<30: self = .previous30Days
        default:
            let comps = calendar.dateComponents([.year, .month], from: date)
            self = .month(calendar.date(from: comps) ?? day)
        }
    }

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .previous7Days: return "Previous 7 days"
        case .previous30Days: return "Previous 30 days"
        case .month(let d): return Self.monthFormatter.string(from: d)
        }
    }

    /// Newest-first ordering: the fixed buckets, then months descending.
    private var rank: (Int, TimeInterval) {
        switch self {
        case .today: return (0, 0)
        case .yesterday: return (1, 0)
        case .previous7Days: return (2, 0)
        case .previous30Days: return (3, 0)
        case .month(let d): return (4, -d.timeIntervalSinceReferenceDate)
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return f
    }()
}
