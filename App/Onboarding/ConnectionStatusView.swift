import SwiftUI
import SwiftData
import NotitimeCore

/// État de la connexion : workspace en titre, bases liées en tableau, et
/// déconnexion avec avertissement si des entrées attendent (FR-007, FR-008).
struct ConnectionStatusView: View {

    @ObservedObject var model: OnboardingModel
    @Query private var connections: [NotionConnection]
    @Query private var bindings: [DatabaseBinding]
    @Query private var pending: [OutboxEntry]

    @State private var confirmingDisconnect = false
    /// Rôle dont l'utilisateur veut changer la base, `nil` quand la feuille est
    /// fermée. Porte l'identité de la feuille : la présenter par un booléen
    /// séparé laisserait une fenêtre où le rôle n'est pas encore connu.
    @State private var rebinding: DatabaseRole?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let connection = connections.first {
                header(connection)
                databases
                Divider()
                disconnect
            }
        }
        .sheet(item: $rebinding) { role in
            DatabasePickerSheet(model: model, role: role) { rebinding = nil }
        }
    }

    // MARK: - En-tête

    @ViewBuilder
    private func header(_ connection: NotionConnection) -> some View {
        HStack(alignment: .center, spacing: 10) {
            WorkspaceIconView(icon: connection.icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(connection.workspaceName.isEmpty ? "Workspace Notion" : connection.workspaceName)
                    .font(Typography.heading)
                    .lineLimit(1)
                Text(ConnectionStatusView.connectedLabel(connection.connectedAt))
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    /// « Connecté le 27 août 2026 à 16:20 » — la date compte : une liaison
    /// vieille de plusieurs mois explique bien des surprises de schéma.
    static func connectedLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return "Connecté le \(formatter.string(from: date))"
    }

    // MARK: - Bases liées (FR-007)

    private var rows: [DatabaseRow] {
        DatabaseRole.allCases.map { role in
            let binding = bindings.first { $0.roleRaw == role.rawValue }
            return DatabaseRow(
                role: role,
                source: binding.map { $0.dataSourceName.isEmpty ? $0.title : $0.dataSourceName },
                isOptional: role == .projects
            )
        }
    }

    @ViewBuilder
    private var databases: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bases liées").font(Typography.heading)
            Table(rows) {
                TableColumn("Rôle") { row in
                    Text(row.label)
                }
                .width(min: 90, ideal: 110)

                TableColumn("Base de données") { row in
                    if let source = row.source {
                        Text(source).lineLimit(1)
                    } else {
                        Text(row.isOptional ? "optionnelle" : "à désigner")
                            .foregroundStyle(row.isOptional ? Color.secondary : Color.orange)
                    }
                }

                TableColumn("") { row in
                    // FR-007 : changer de base à tout moment, la revalidation
                    // ayant lieu avant que le changement ne soit accepté.
                    Button(row.source == nil ? "Désigner…" : "Modifier…") {
                        rebinding = row.role
                    }
                    .buttonStyle(.link)
                }
                .width(80)
            }
            .frame(minHeight: 108, maxHeight: 132)
            Text("Chaque changement revalide le schéma de la base avant d'être accepté.")
                .font(Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Déconnexion

    @ViewBuilder
    private var disconnect: some View {
        Button("Se déconnecter") { confirmingDisconnect = true }
            .confirmationDialog(disconnectPrompt, isPresented: $confirmingDisconnect) {
                Button("Se déconnecter", role: .destructive) {
                    // Se déconnecter n'est pas s'installer : on reste où l'on
                    // est, avec le bouton de connexion sous les yeux. L'accueil
                    // est un premier pas, pas une punition de fin de session.
                    Task { await model.disconnect() }
                }
                Button("Annuler", role: .cancel) {}
            }
    }

    /// FR-008 : avertir si des entrées sont encore en attente d'envoi.
    private var disconnectPrompt: String {
        pending.isEmpty
            ? "Se déconnecter de Notion ?"
            : "\(pending.count) entrée(s) attendent d'être envoyées. Elles resteront en file "
            + "et repartiront à la prochaine connexion. Se déconnecter ?"
    }
}

/// Une ligne du tableau des bases.
struct DatabaseRow: Identifiable {
    let role: DatabaseRole
    let source: String?
    let isOptional: Bool

    var id: String { role.rawValue }

    var label: String {
        switch role {
        case .tasks: return "Tâches"
        case .timeEntries: return "Time Entries"
        case .projects: return "Projets"
        }
    }
}

/// Icône du workspace : image distante ou emoji, selon ce que Notion renvoie.
struct WorkspaceIconView: View {

    let icon: WorkspaceIcon
    var side: CGFloat = 34

    /// L'image, si elle est déjà connue au moment de construire la vue.
    ///
    /// Lue ici et non dans une tâche : une valeur posée après le premier rendu
    /// ferait passer le squelette de « pas encore » à « voilà », donc rejouerait
    /// le fondu pour une image qui n'a jamais eu à attendre.
    @State private var image: NSImage?

    init(icon: WorkspaceIcon, side: CGFloat = 34) {
        self.icon = icon
        self.side = side
        if case .image(let url) = icon {
            _image = State(initialValue: ImageStore.shared.cached(url))
        }
    }

    var body: some View {
        Group {
            switch icon {
            case .image(let url):
                // Le squelette et son fondu ne valent que pour une vraie
                // attente : déjà lue, l'icône est là dès le premier rendu et
                // rien ne s'anime.
                SkeletonReveal(isRevealed: image != nil) {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                } placeholder: {
                    skeleton
                }
                .task(id: url) {
                    guard image == nil else { return }
                    image = await ImageStore.shared.image(at: url)
                }
            case .emoji(let emoji):
                Text(emoji).font(.system(size: side * 0.62))
            case .none:
                placeholder
            }
        }
        .frame(width: side, height: side)
        .background(Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var placeholder: some View {
        Image(systemName: "square.grid.2x2")
            .foregroundStyle(.secondary)
    }

    /// Le squelette occupe exactement la place de l'icône : c'est ce qui rend
    /// l'échange invisible en mise en page.
    private var skeleton: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Color.secondary.opacity(0.22))
    }
}

/// Choix d'une autre source pour un rôle donné (FR-007).
///
/// La feuille travaille sur son propre état : elle ne change jamais l'étape du
/// modèle, sans quoi l'écran qui la présente serait remplacé et la feuille
/// disparaîtrait avec lui.
///
/// Elle a deux pages : la liste des bases, et le guide de partage quand la base
/// cherchée n'y est pas. Deux pages dans une seule feuille plutôt que deux
/// feuilles empilées : on revient à la liste là où on l'avait laissée.
struct DatabasePickerSheet: View {

    @ObservedObject var model: OnboardingModel
    let role: DatabaseRole
    let onClose: () -> Void

    private enum LoadState {
        case loading
        case loaded([AccessibleSource])
        case failed(String)
    }

    private enum Page {
        case list
        case guide
    }

    /// Taille commune aux deux pages : la feuille ne change pas de dimensions
    /// en cours de route, et le passage de l'une à l'autre se lit comme un
    /// glissement plutôt que comme un saut.
    static let size = CGSize(width: 460, height: 520)

    @State private var state: LoadState = .loading
    @State private var page: Page = .list
    @State private var search = ""
    @State private var refused: [PropertyKey] = []
    @State private var isAssigning = false
    /// Les bases connues au chargement précédent : ce qui n'y était pas
    /// clignote une fois, le temps de se faire remarquer.
    @State private var known: Set<String> = []
    @State private var highlighted: Set<String> = []
    @State private var hasLoaded = false
    @State private var isLoading = false

    /// Ce que la recherche a renvoyé récemment, et quand pour chaque source.
    ///
    /// La recherche de Notion n'est pas stable d'un appel à l'autre : le même
    /// espace a renvoyé neuf sources, puis trois, puis neuf à nouveau, sans que
    /// rien n'ait changé entre-temps. Une base vue il y a moins d'une minute
    /// reste donc listée le temps que la recherche se reprenne, plutôt que de
    /// disparaître sous le curseur — et si elle a vraiment été retirée, la
    /// liaison la refusera, ce qu'elle vérifie de toute façon.
    @State private var catalogue: [String: AccessibleSource] = [:]
    @State private var lastSeen: [String: ContinuousClock.Instant] = [:]
    /// Jusqu'à quand la veille est pressée, `nil` le reste du temps.
    @State private var hurryUntil: ContinuousClock.Instant?

    /// Cadence de la veille tant que la feuille est ouverte.
    ///
    /// Le limiteur de l'application plafonne l'ensemble à trois requêtes par
    /// seconde (FR-029) et une relecture n'en coûte qu'une : une seconde de
    /// période laisse les deux tiers du débit au reste de l'application.
    private static let pollInterval = Duration.seconds(1)
    /// Cadence resserrée après « C'est fait » : c'est le seul moment où
    /// quelqu'un attend, les yeux sur la liste.
    private static let hurriedInterval = Duration.milliseconds(500)
    private static let hurryDuration = Duration.seconds(20)
    /// Délai avant d'oublier une source que la recherche ne renvoie plus.
    private static let grace = Duration.seconds(45)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch page {
            case .list:
                list
                    .transition(.page(forward: false))
            case .guide:
                // « C'est fait » ne ferme pas seulement le guide : il relance la
                // recherche, sans quoi l'utilisateur devrait redemander lui-même
                // ce qu'il vient tout juste d'autoriser.
                ConnectGuideView(onBack: { page = .list },
                                 onDone: {
                                     page = .list
                                     Task { await hurry() }
                                 })
                    .transition(.page(forward: true))
            }
        }
        // Les deux pages se croisent au lieu de se remplacer : le guide entre
        // par la droite, la liste revient par la gauche.
        .animation(Motion.ease(Motion.panelOpen), value: page)
        .task { await watch() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choisir la base « \(DatabaseRow(role: role, source: nil, isOptional: false).label) »")
                .font(Typography.heading)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // FR-006 : un schéma incomplet se dit, et n'est pas accepté.
            if !refused.isEmpty {
                Text("Base refusée — propriétés manquantes : "
                     + refused.map(\.rawValue).joined(separator: ", "))
                    .font(Typography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // Là où se trouvait « Recharger » : à cet endroit, la question
                // n'est pas de relire la liste mais de comprendre pourquoi la
                // base n'y figure pas.
                // Même police et même hauteur que les boutons du guide : ce
                // sont deux pages d'une même feuille, pas deux écrans.
                Button { page = .guide } label: {
                    Text("Je ne trouve pas ma base de données").controlLabel()
                }
                Spacer()
                Button { onClose() } label: {
                    Text("Fermer").controlLabel()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: DatabasePickerSheet.size.width,
               height: DatabasePickerSheet.size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            // Rien de la liste pendant la recherche : une liste incomplète qui
            // se complète sous les yeux se lit comme une liste complète.
            ShimmerText(text: "On cherche tes bases de données")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text("Impossible de lire vos bases.").font(Typography.body)
                Text(message)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)

        case .loaded(let sources) where sources.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Text("Aucune base n'est partagée avec Notitime. Ouvrez la base dans "
                     + "Notion, puis « Connexions » → Notitime.")
                    .font(Typography.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Dire que la veille tourne évite de fermer la feuille pour la
                // rouvrir : ce qui sera partagé arrivera tout seul.
                Text("On continue de chercher — dès qu'une base est partagée, elle apparaît ici.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.rising)

        case .loaded(let sources):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("Rechercher une base", text: $search)
                        .textFieldStyle(.roundedBorder)
                        .font(Typography.body)
                    // Une icône suffit : le geste est celui d'un rafraîchissement,
                    // et il se lit mieux à côté de la recherche qu'en bas de page.
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise").controlLabel()
                    }
                    .help("Chercher à nouveau")
                    .accessibilityLabel("Chercher à nouveau")
                }
                if hurryUntil != nil {
                    // Après « C'est fait », la liste reste en place et cette
                    // ligne dit que la recherche continue : sans elle, une
                    // liste inchangée passerait pour une recherche ratée.
                    ShimmerText(text: "On cherche tes nouvelles bases…",
                                font: Typography.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                List(filtered(sources)) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name.isEmpty ? "Sans titre" : source.name)
                                .font(Typography.body)
                            if model.bindings[role] == source.name {
                                Text("Base actuellement liée")
                                    .font(Typography.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button { Task { await choose(source) } } label: {
                            Text("Lier").controlLabel()
                        }
                        .disabled(isAssigning)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.accentColor
                                .opacity(highlighted.contains(source.id) ? 0.28 : 0))
                    )
                }
            }
            .transition(.rising)
        }
    }

    private func filtered(_ sources: [AccessibleSource]) -> [AccessibleSource] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return sources }
        return sources.filter { $0.name.lowercased().contains(needle) }
    }

    /// Première lecture, puis veille jusqu'à la fermeture de la feuille.
    ///
    /// La veille couvre les deux pages : une base partagée pendant que le guide
    /// est affiché est déjà là au retour. C'est ce qui évite le pire des cas —
    /// « C'est fait », une recherche qui scintille, et rien au bout.
    private func watch() async {
        await load()
        var next = ContinuousClock.now
        while !Task.isCancelled {
            if let until = hurryUntil, ContinuousClock.now > until { hurryUntil = nil }
            next = next.advanced(by: hurryUntil == nil ? Self.pollInterval
                                                       : Self.hurriedInterval)
            try? await Task.sleep(until: next, clock: .continuous)
            guard !Task.isCancelled else { return }
            await refresh()
            // Période comptée de départ à départ. Comptée de la fin d'un appel
            // au début du suivant, la latence du réseau s'y ajoutait : une
            // seconde demandée en faisait deux. Et si un appel déborde, on
            // repart de maintenant plutôt que d'enchaîner pour rattraper.
            if ContinuousClock.now > next { next = ContinuousClock.now }
        }
    }

    /// Ce que déclenche « C'est fait » : une recherche immédiate, puis une
    /// veille resserrée pendant vingt secondes. La liste ne se vide pas pour
    /// autant — elle n'a aucune raison d'oublier ce qu'elle affiche déjà.
    private func hurry() async {
        hurryUntil = ContinuousClock.now.advanced(by: Self.hurryDuration)
        if catalogue.isEmpty {
            await load()
        } else {
            await refresh()
        }
    }

    /// Fusionne ce que la recherche vient de renvoyer avec ce qu'on a vu
    /// récemment, et rend la liste à afficher.
    private func merged(with sources: [AccessibleSource]) -> [AccessibleSource] {
        let now = ContinuousClock.now
        for source in sources {
            catalogue[source.id] = source
            lastSeen[source.id] = now
        }
        for (id, seen) in lastSeen where now - seen > Self.grace {
            lastSeen[id] = nil
            catalogue[id] = nil
        }
        return catalogue.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Relecture silencieuse : pas de scintillement, pas de liste vidée. Rien
    /// ne bouge tant que rien n'a changé, et ce qui apparaît clignote.
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard (try? await model.fetchAccessibleSources()) != nil else { return }
        let sources = merged(with: model.accessibleSources)
        let ids = Set(sources.map(\.id))
        guard ids != known || !hasLoaded else { return }

        let fresh = hasLoaded ? ids.subtracting(known) : []
        known = ids
        hasLoaded = true
        withAnimation(Motion.ease(0.4)) { state = .loaded(sources) }
        await blink(fresh)
    }

    private func load() async {
        // Deux chargements en même temps — la tâche d'ouverture et « C'est
        // fait », par exemple — feraient deux appels pour un seul résultat.
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        highlighted = []
        withAnimation(Motion.ease(0.25)) { state = .loading }
        do {
            try await model.fetchAccessibleSources()
            let sources = merged(with: model.accessibleSources)
            let ids = Set(sources.map(\.id))
            // Rien ne clignote au premier chargement : tout y est nouveau, et
            // tout ferait clignoter la liste entière.
            let fresh = hasLoaded ? ids.subtracting(known) : []
            known = ids
            hasLoaded = true
            withAnimation(Motion.ease(0.4)) { state = .loaded(sources) }
            await blink(fresh)
        } catch {
            withAnimation(Motion.ease(0.25)) { state = .failed(String(describing: error)) }
        }
    }

    /// Deux battements brefs sur les bases qui viennent d'apparaître : assez
    /// pour attirer l'œil, trop courts pour devenir une décoration.
    private func blink(_ ids: Set<String>) async {
        guard !ids.isEmpty, !reduceMotion else { return }
        // La liste se pose d'abord : un clignotement pendant l'apparition se
        // confondrait avec elle.
        try? await Task.sleep(for: .milliseconds(350))
        for _ in 0..<2 {
            withAnimation(.easeOut(duration: 0.12)) { highlighted = ids }
            try? await Task.sleep(for: .milliseconds(140))
            withAnimation(.easeIn(duration: 0.22)) { highlighted = [] }
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    /// La feuille ne se ferme que si la base a été acceptée : un schéma
    /// incomplet doit rester visible là où le choix a été fait.
    private func choose(_ source: AccessibleSource) async {
        isAssigning = true
        defer { isAssigning = false }
        refused = []

        let accepted = await model.assign(dataSourceID: source.id,
                                          databaseID: source.databaseID,
                                          name: source.name, to: role,
                                          changesStep: false)
        if accepted {
            onClose()
        } else {
            refused = model.missingByRole[role] ?? []
        }
    }
}
