import SwiftUI

/// Un calendrier au mois, compact.
///
/// Écrit à la main plutôt que confié à `DatePicker(.graphical)` : celui-ci
/// occupe près de 250 points de haut, quand le panneau de la barre de menus en
/// fait 300 en tout. Ici, une grille de six semaines tient en 170.
struct MonthCalendar: View {

    @Binding var selection: Date?
    /// Le mois affiché — il n'est pas forcément celui de la date choisie : on
    /// peut vouloir regarder novembre sans avoir encore rien choisi.
    @State private var month: Date

    private let calendar: Calendar

    init(selection: Binding<Date?>) {
        _selection = selection
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "fr_FR")
        // La semaine commence lundi : c'est ce que dit le calendrier français,
        // et une grille qui commence dimanche se lit de travers.
        calendar.firstWeekday = 2
        self.calendar = calendar
        _month = State(initialValue: calendar.startOfDay(for: selection.wrappedValue ?? Date()))
    }

    /// Le gabarit d'une case. Le panneau de la barre de menus fait 300 points
    /// de haut : six semaines, leurs en-têtes et deux raccourcis doivent y tenir
    /// avec la ligne d'écriture au-dessus.
    private static let cell = CGSize(width: 24, height: 18)

    var body: some View {
        VStack(spacing: 5) {
            shortcuts
            header
            grid
        }
    }

    // MARK: - Aujourd'hui et demain

    /// Deux colonnes au-dessus du mois : neuf échéances sur dix sont l'une ou
    /// l'autre, et les chercher dans une grille pour les désigner serait un
    /// détour.
    private var shortcuts: some View {
        HStack(spacing: 6) {
            shortcut("Aujourd'hui", days: 0)
            shortcut("Demain", days: 1)
        }
    }

    private func shortcut(_ title: LocalizedStringKey, days: Int) -> some View {
        let day = calendar.startOfDay(for: calendar.date(byAdding: .day, value: days, to: Date()) ?? Date())
        return Button {
            selection = day
            month = day
        } label: {
            Text(title)
                .font(Typography.control)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isSelected(day) ? Color.accentColor.opacity(0.20)
                                              : Color.primary.opacity(0.06))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Le mois

    private var header: some View {
        HStack {
            step(-1, symbol: "chevron.left")
            Spacer()
            Text(MonthCalendar.monthTitle.string(from: month).capitalized)
                .font(Typography.control)
            Spacer()
            step(1, symbol: "chevron.right")
        }
    }

    private func step(_ months: Int, symbol: String) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: months, to: month) {
                month = next
            }
        } label: {
            Image(systemName: symbol)
                .font(Typography.caption)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var grid: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(Typography.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: MonthCalendar.cell.width)
                }
            }
            ForEach(weeks, id: \.first) { week in
                HStack(spacing: 2) {
                    ForEach(week, id: \.self) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let inMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)
        Button {
            selection = day
        } label: {
            Text(MonthCalendar.dayNumber.string(from: day))
                .font(Typography.caption)
                // Les jours des mois voisins restent lisibles mais s'effacent :
                // ils bouchent la grille, ils ne s'y proposent pas.
                .foregroundStyle(inMonth ? (isSelected(day) ? Color.white : Color.primary)
                                         : Color.secondary.opacity(0.5))
                .frame(width: MonthCalendar.cell.width, height: MonthCalendar.cell.height)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected(day) ? Color.accentColor : .clear)
                )
                .overlay {
                    // Aujourd'hui se repère même quand un autre jour est choisi.
                    if calendar.isDateInToday(day) && !isSelected(day) {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isSelected(_ day: Date) -> Bool {
        guard let selection else { return false }
        return calendar.isDate(day, inSameDayAs: selection)
    }

    // MARK: - La grille

    /// Six semaines, toujours : une grille dont la hauteur change d'un mois à
    /// l'autre ferait sauter tout ce qui est en dessous.
    private var weeks: [[Date]] {
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let start = calendar.dateInterval(of: .weekOfMonth, for: first)?.start
        else { return [] }
        return (0..<6).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: start)
            }
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return (0..<7).map { symbols[($0 + first) % 7].uppercased() }
    }

    static let monthTitle: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
        return formatter
    }()

    static let dayNumber: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "d"
        return formatter
    }()
}
