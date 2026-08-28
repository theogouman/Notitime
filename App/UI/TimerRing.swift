import SwiftUI

/// Cadran de minuteur, sur le modèle de l'app Horloge de macOS.
///
/// Un anneau plein pour la durée choisie, un arc qui se rétracte pour ce qu'il
/// en reste, et au centre l'heure de fin puis le temps restant. Le temps se lit
/// alors de deux façons : au chiffre près, et d'un coup d'œil à la part d'arc
/// qui reste — c'est cette seconde lecture que le seul compteur ne donnait pas.
struct TimerRing: View {

    /// Temps restant, déjà mis en forme (`mm:ss`).
    let label: String
    /// Part de la durée qui reste, de 1 au départ à 0 à l'échéance.
    let progress: Double
    /// Heure à laquelle la sonnerie tombera, si elle est connue.
    var endsAt: Date?
    var tint: Color = .accentColor
    var diameter: CGFloat = 164

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var width: CGFloat { 7 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: width)

            Circle()
                // Un arc strictement nul disparaît d'un coup ; on lui laisse de
                // quoi rester visible jusqu'à la dernière seconde.
                .trim(from: 0, to: max(0.0001, min(1, progress)))
                .stroke(tint, style: StrokeStyle(lineWidth: width, lineCap: .round))
                // Le départ à midi, sans quoi l'arc commencerait à trois heures.
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .linear(duration: 0.25), value: progress)

            VStack(spacing: 4) {
                if let endsAt {
                    Label(TimerRing.clock.string(from: endsAt), systemImage: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
                Text(label)
                    .font(.system(size: 38, weight: .light))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(.easeOut(duration: 0.25), value: label)
            }
        }
        .frame(width: diameter, height: diameter)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
