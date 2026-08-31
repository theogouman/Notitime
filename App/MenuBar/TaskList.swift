import SwiftUI
import AppKit
import NotitimeCore

/// Liste des tâches du menu : recherche locale, récentes en tête, puis le reste.
///
/// Une ligne se choisit d'un clic ; c'est le conteneur qui décide ce que ce clic
/// déclenche — ici, le dépliement du panneau de lancement.
struct TaskList: View {

    @ObservedObject var controller: SessionController
    @Binding var query: String
    /// Ligne survolée au clavier, distincte de la tâche dépliée.
    @Binding var highlighted: String?
    let select: (CachedTaskItem) -> Void

    /// Le champ de recherche a le focus. Un simple état : `SearchField` tient
    /// le sien et s'y synchronise.
    @State private var searchFocused = false
    /// Ligne sous le curseur. Distincte de `highlighted`, qui suit le clavier :
    /// les deux désignations coexistent sans se marcher dessus.
    @State private var hovered: String?

    /// La tâche en cours d'écriture, `nil` quand aucune ne l'est.
    @State private var draftTitle: String?
    @State private var draftProject: ProjectSummary?
    @State private var draftDue: Date?
    /// Le sélecteur déplié sous la ligne d'écriture, s'il y en a un.
    @State private var draftPicker: DraftPicker?
    @State private var projectQuery = ""
    @FocusState private var draftFocused: Bool
    /// Les lignes ont pris leur place, ou montent encore vers elle.
    @State private var revealed = false
    /// Hauteur du sélecteur ouvert, mesurée à l'affichage.
    @State private var pickerHeight: CGFloat = 0
    /// Projet sous le curseur, dans le sélecteur.
    @State private var hoveredProject: String?
    /// Le menu ouvert dans une ligne, s'il y en a un. Un seul à la fois : deux
    /// menus natifs ouverts en même temps n'ont aucun sens.
    @State private var openMenu: RowMenu?

    /// Les deux menus qu'une ligne peut ouvrir, identifiés par la tâche.
    private enum RowMenu: Equatable {
        case status(String)
        case actions(String)
    }

    private enum DraftPicker: String, Identifiable {
        case project, date
        var id: String { rawValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            search

            if controller.isLoadingTasks || (controller.tasks.isEmpty && draftTitle == nil) {
                // Le message occupe tout ce qui reste et s'y centre : posé en
                // haut, il flottait sous la recherche avec du vide dessous.
                TaskListStates(controller: controller, query: $query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                rows
            }
        }
        .onAppear {
            // Rouvrir le menu ne doit pas retrouver une ligne d'écriture restée
            // vide : elle n'a jamais existé ailleurs que dans cette vue.
            discardEmptyDraft()
            searchFocused = true
            // Les lignes sont déjà en place : elles montent à l'arrivée des
            // tâches, pas à chaque retour sur la liste. Rejouer l'entrée ici
            // faisait flouter dix lignes pendant que la fenêtre changeait de
            // taille — deux animations lourdes sur le même dixième de seconde,
            // et c'est le redimensionnement qui saccadait.
            revealed = true
        }
        // Le panneau se referme dès qu'il perd le premier plan : c'est là qu'on
        // abandonne une tâche qu'on n'a pas nommée.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            discardEmptyDraft()
        }
        .onChange(of: controller.isLoadingTasks) { _, loading in
            if loading { revealed = false } else { reveal() }
        }
        // Le sélecteur ouvert chevauche la liste : il se pose sous le bouton qui
        // l'appelle, à sa propre taille, et rien ne bouge derrière lui.
        .overlayPreferenceValue(DraftAnchors.self) { anchors in
            floatingPicker(anchors)
        }
    }

    /// Fait monter les lignes à leur place, l'une après l'autre.
    private func reveal() {
        guard !controller.tasks.isEmpty else { return revealed = false }
        guard !reduceMotion else { return revealed = true }
        revealed = false
        // Le changement doit être vu comme un changement : posé dans le même
        // tour de boucle que l'état de départ, il n'animerait rien.
        DispatchQueue.main.async { revealed = true }
    }

    // MARK: - Recherche et création

    private var search: some View {
        HStack(spacing: 6) {
            // FR-013 — filtre local, sans requête réseau.
            // Le champ est actif dès l'ouverture du panneau : son halo bleu ne
            // disait rien qu'on ne sache déjà, et le liseré creusé d'AppKit
            // faisait ressembler le menu à un formulaire (voir `SearchField`).
            SearchField(placeholder: "Rechercher une tâche…",
                        text: $query,
                        isFocused: $searchFocused) {
                if let task = highlightedTask ?? controller.tasks.first { choose(task) }
            }
            .onChange(of: query) { _, text in Task { await controller.search(text) } }

            Button(action: startDraft) {
                Image(systemName: "plus")
                    .font(Typography.control)
                    .frame(width: 16, height: 16)
            }
            .help("Nouvelle tâche dans Notion")
            .accessibilityLabel("Nouvelle tâche dans Notion")
            .disabled(controller.isCreatingTask)
        }
    }

    /// Ouvre une ligne vierge en tête de liste. Les autres descendent d'un cran
    /// pour lui faire place : la tâche naît là où on la lira ensuite.
    private func startDraft() {
        searchFocused = false
        draftProject = nil
        draftDue = nil
        draftPicker = nil
        withAnimation(reduceMotion ? nil : Motion.ease(Motion.panelOpen)) {
            draftTitle = ""
        }
        // Les projets arrivent pendant qu'on écrit le titre : demandés au clic
        // sur « Projet », ils feraient attendre devant une liste vide.
        Task { await controller.loadProjects() }
    }

    /// Abandonne la ligne d'écriture si elle n'a pas reçu de titre. Rien n'a été
    /// créé dans Notion à ce stade : il n'y a que cette vue à nettoyer.
    private func discardEmptyDraft() {
        guard let title = draftTitle,
              title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draftPicker = nil
        draftTitle = nil
        draftProject = nil
        draftDue = nil
    }

    private func cancelDraft() {
        draftPicker = nil
        withAnimation(reduceMotion ? nil : Motion.ease(Motion.pageDuration)) {
            draftTitle = nil
        }
        searchFocused = true
    }

    private func commitDraft() {
        guard let title = draftTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return cancelDraft() }
        let project = draftProject?.id
        let due = draftDue
        draftPicker = nil
        Task {
            // La tâche créée n'est pas désignée au retour : elle prend sa place
            // dans la liste comme les autres, sans fond de sélection.
            _ = await controller.createTask(titled: title,
                                            projectPageID: project, due: due)
            withAnimation(reduceMotion ? nil : Motion.ease(Motion.panelOpen)) {
                draftTitle = nil
            }
            searchFocused = true
        }
    }

    /// Rendre le focus **avant** de changer de panneau.
    ///
    /// Les deux panneaux se croisent en fondu : un champ encore focalisé au
    /// départ emporte son anneau bleu dans la transition, et celui-ci reste
    /// visible par-dessus le panneau de méthode le temps de l'animation. Le
    /// rendre en partant arrivait trop tard, précisément pour cette raison.
    private func choose(_ task: CachedTaskItem) {
        searchFocused = false
        select(task)
    }

    private var highlightedTask: CachedTaskItem? {
        controller.tasks.first { $0.id == highlighted }
    }

    /// FR-014 — les récentes forment une section à part, en tête.
    private var recents: [CachedTaskItem] {
        controller.tasks.filter { controller.recentIDs.contains($0.id) }
    }

    private var others: [CachedTaskItem] {
        controller.tasks.filter { !controller.recentIDs.contains($0.id) }
    }

    @ViewBuilder
    private var rows: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if draftTitle != nil {
                        draftRow
                            // Elle arrive par le haut, et pousse le reste vers
                            // le bas : le mouvement dit d'où vient la ligne.
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !recents.isEmpty {
                        section("Récentes", recents, from: 0)
                        if !others.isEmpty {
                            section("Toutes les tâches", others, from: recents.count)
                        }
                    } else {
                        ForEach(Array(controller.tasks.enumerated()), id: \.element.id) { rank, task in
                            row(task, rank: rank)
                        }
                    }
                }
            }
            .onChange(of: highlighted) { _, id in
                guard let id else { return }
                withAnimation(.linear(duration: 0.1)) { scroll.scrollTo(id, anchor: .center) }
            }
            // Aucune ligne ne porte l'anneau du système : le clavier peut poser
            // son focus sur le premier bouton de la liste, ce qui la teintait
            // sans qu'on ait rien choisi. Le survol reste le seul marqueur.
            .focusEffectDisabled()
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [CachedTaskItem], from rank: Int) -> some View {
        Text(title)
            .font(Typography.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .padding(.horizontal, 4)
        ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
            row(task, rank: rank + index)
        }
    }

    // MARK: - Une ligne

    @ViewBuilder
    private func row(_ task: CachedTaskItem, rank: Int) -> some View {
        // Plus un bouton, mais une ligne qui se clique : elle porte désormais
        // deux contrôles à elle — le statut et le menu d'actions —, et un bouton
        // logé dans le libellé d'un autre bouton ne reçoit aucun clic.
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(Typography.body)
                    .lineLimit(1)
                details(task)
            }
            Spacer(minLength: 0)
            actions(task)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(background(of: task))
        )
        .contentShape(Rectangle())
        .onTapGesture { choose(task) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { choose(task) }
        // Les lignes montent à leur place l'une après l'autre : la liste se
        // pose, au lieu d'apparaître d'un bloc à la fin du chargement. Le
        // décalage est plafonné — au-delà de neuf lignes, l'attente se verrait
        // plus que le mouvement.
        .offset(y: revealed ? 0 : Motion.rowsDistance)
        .scaleEffect(revealed ? 1 : Motion.rowsScale, anchor: .top)
        .opacity(revealed ? 1 : 0)
        .animation(reduceMotion ? nil
                   : Motion.ease(Motion.rowsDuration)
                       .delay(Double(min(rank, 8)) * Motion.rowsStep),
                   value: revealed)
        // Le survol se voit : sans lui, rien ne dit qu'une ligne se clique.
        .onHover { inside in
            guard !reduceMotion else { return hovered = inside ? task.id : (hovered == task.id ? nil : hovered) }
            withAnimation(Motion.ease(0.12)) {
                if inside { hovered = task.id }
                else if hovered == task.id { hovered = nil }
            }
        }
        .id(task.id)
    }

    /// Un seul effet de fond, et il est neutre.
    ///
    /// La teinte d'accent marquait la ligne désignée au clavier — mais elle
    /// survivait au retour d'une session et donnait à la première tâche l'air
    /// d'être sélectionnée alors que rien ne l'était. Une désignation qui n'a
    /// pas été demandée ne doit rien colorer : le curseur et les flèches posent
    /// désormais le même voile discret, celui du survol.
    private func background(of task: CachedTaskItem) -> Color {
        hovered == task.id || highlighted == task.id
            ? Color.primary.opacity(0.06)
            : .clear
    }

    /// Le statut, le projet et l'échéance, sur la même ligne : trois repères qui
    /// disent, sans ouvrir Notion, où en est la tâche, à quoi elle se rattache et
    /// pour quand elle est.
    @ViewBuilder
    private func details(_ task: CachedTaskItem) -> some View {
        let project = controller.projectName(of: task)
        let due = task.dueDate.map(TaskList.day)
        if showsStatus(of: task) || project != nil || due != nil {
            HStack(spacing: 5) {
                if showsStatus(of: task) {
                    statusChip(task)
                }
                if let project {
                    Text(project).lineLimit(1)
                }
                if project != nil && due != nil {
                    Text(verbatim: "·").foregroundStyle(.tertiary)
                }
                if let due {
                    HStack(spacing: 3) {
                        Image(systemName: "calendar")
                        Text(due)
                    }
                }
            }
            .font(Typography.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Une base sans propriété de statut n'a rien à afficher ni à proposer : le
    /// bouton n'ouvrirait qu'un menu vide.
    private func showsStatus(of task: CachedTaskItem) -> Bool {
        task.statusValue != nil || !controller.statusOptions.isEmpty
    }

    /// Le statut, cliquable : une pastille qui dit où en est la tâche et ouvre
    /// les valeurs que la base déclare.
    private func statusChip(_ task: CachedTaskItem) -> some View {
        Button { openMenu = .status(task.id) } label: {
            HStack(spacing: 3) {
                Text(task.statusValue ?? "Sans statut")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(Typography.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous).fill(Color.primary.opacity(0.07))
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Changer le statut dans Notion")
        .background {
            // L'ancre n'est posée que pour la ligne dont le menu s'ouvre. Une
            // par ligne et par menu, c'étaient vingt vues AppKit remises à jour
            // à chaque passe de mise en page — y compris aux soixante passes
            // d'un changement de taille de la fenêtre.
            if openMenu == .status(task.id) {
                NativeMenuAnchor(header: "Statut",
                                 entries: statusEntries(task),
                                 emptyTitle: "Cette base ne déclare aucun statut",
                                 matchesAnchorWidth: false,
                                 isPresented: menu(.status(task.id)))
            }
        }
    }

    private func statusEntries(_ task: CachedTaskItem) -> [NativeMenuEntry] {
        controller.statusOptions.map { option in
            NativeMenuEntry(id: option.name,
                            title: option.name,
                            isOn: option.name == task.statusValue) {
                // L'écriture part maintenant, la liste suit quand Notion a
                // répondu : c'est le contrôleur qui anime la sortie d'une tâche
                // passée dans le groupe « terminé ».
                Task { await controller.setStatus(option.name, on: task) }
            }
        }
    }

    /// Les trois gestes d'une ligne, sous les trois points : ouvrir la tâche là
    /// où elle vit, la lancer, ou ne plus la voir.
    private func actions(_ task: CachedTaskItem) -> some View {
        Button { openMenu = .actions(task.id) } label: {
            Image(systemName: "ellipsis")
                .font(Typography.caption)
                .foregroundStyle(.tertiary)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Actions sur cette tâche")
        .accessibilityLabel("Actions sur cette tâche")
        .background {
            if openMenu == .actions(task.id) {
                NativeMenuAnchor(entries: actionEntries(task),
                                 matchesAnchorWidth: false,
                                 isPresented: menu(.actions(task.id)))
            }
        }
    }

    private func actionEntries(_ task: CachedTaskItem) -> [NativeMenuEntry] {
        [
            NativeMenuEntry(id: "open", title: "Ouvrir dans Notion",
                            symbols: ["arrow.up.right"]) {
                controller.openInNotion(task)
            },
            NativeMenuEntry(id: "start", title: "Démarrer une session",
                            symbols: ["bolt.fill"]) {
                choose(task)
            },
            NativeMenuEntry(id: "hide", title: "Ne plus afficher",
                            symbols: ["eye.slash"], startsSection: true) {
                withAnimation(reduceMotion ? nil : Motion.ease(Motion.pageDuration)) {
                    controller.hide(task)
                }
            }
        ]
    }

    /// Le menu d'une ligne est ouvert, ou ne l'est pas. Un seul à la fois.
    private func menu(_ target: RowMenu) -> Binding<Bool> {
        Binding(get: { openMenu == target },
                set: { openMenu = $0 ? target : nil })
    }

    /// L'échéance, dite comme on la dirait.
    ///
    /// « Aujourd'hui » et « Demain » sont ce qu'on cherche à savoir d'une liste
    /// de tâches : lire « 30 août » oblige à faire le calcul soi-même, à chaque
    /// ligne. Au-delà de la veille et du lendemain, la date reprend ses droits —
    /// « dans trois jours » demanderait le calcul inverse.
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Aujourd'hui") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Demain") }
        if calendar.isDateInYesterday(date) { return String(localized: "Hier") }
        return dayFormatter.string(from: date)
    }

    /// « 12 sept. » dans l'année en cours, « 12 sept. 2027 » au-delà : l'année
    /// n'apprend rien onze fois sur douze, et manque cruellement la douzième.
    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "fr_FR")
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter
    }()

    // MARK: - La ligne en cours d'écriture

    private var draftRow: some View {
        HStack(spacing: 6) {
            TextField("Titre de la nouvelle tâche", text: Binding(
                get: { draftTitle ?? "" },
                set: { draftTitle = $0 }))
                .textFieldStyle(.plain)
                .font(Typography.body)
                .focused($draftFocused)
                .onSubmit(commitDraft)
                .disabled(controller.isCreatingTask)
                // Le focus se prend quand le champ existe, et pas avant :
                // demandé au clic sur « + », il portait sur une vue que
                // SwiftUI n'avait pas encore posée, et se perdait. Même
                // `onAppear` est trop tôt — le champ n'est pas encore installé
                // dans la fenêtre — d'où le tour de boucle supplémentaire.
                .onAppear { DispatchQueue.main.async { draftFocused = true } }

            draftButton(.project, symbol: "folder",
                        title: draftProject?.name ?? String(localized: "Projet"),
                        isSet: draftProject != nil)
            draftButton(.date, symbol: "calendar",
                        title: draftDue.map(TaskList.day)
                            ?? String(localized: "Date"),
                        isSet: draftDue != nil)

            Button("Annuler", action: cancelDraft)
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.10))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.accentColor.opacity(0.35))
        }
        .opacity(controller.isCreatingTask ? 0.6 : 1)
    }

    private func draftButton(_ picker: DraftPicker, symbol: String,
                             title: String, isSet: Bool) -> some View {
        Button {
            pickerHeight = 0
            withAnimation(reduceMotion ? nil : Motion.ease(Motion.pageDuration)) {
                draftPicker = draftPicker == picker ? nil : picker
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                Text(verbatim: title).lineLimit(1)
            }
            .font(Typography.caption)
            .foregroundStyle(isSet ? Color.primary : Color.secondary)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isSet ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10))
            }
        }
        .buttonStyle(.plain)
        .disabled(controller.isCreatingTask)
        // Le sélecteur se pose sous ce bouton : il faut donc savoir où il est.
        .anchorPreference(key: DraftAnchors.self, value: .bounds) { [picker.rawValue: $0] }
    }

    // MARK: - Le sélecteur, par-dessus la liste

    /// Le sélecteur ouvert, posé sous le bouton qui l'appelle.
    ///
    /// Il chevauche la liste au lieu de la pousser vers le bas : déplié dans le
    /// flux, il déplaçait tout ce qui suit et le calendrier finissait sous le
    /// bord du panneau. Ce n'est pas un `popover` pour autant — celui-ci ouvre
    /// une fenêtre, et le panneau de la barre de menus se referme dès qu'il perd
    /// le premier plan.
    @ViewBuilder
    private func floatingPicker(_ anchors: [String: Anchor<CGRect>]) -> some View {
        if let picker = draftPicker, let anchor = anchors[picker.rawValue] {
            GeometryReader { proxy in
                let button = proxy[anchor]
                let width = TaskList.pickerWidth(picker)
                // Aligné à droite sur le bouton, et rentré dans le panneau quand
                // il n'y a plus la place.
                let x = min(max(0, button.maxX - width), max(0, proxy.size.width - width))
                // Sous le bouton, sauf s'il n'y a plus la hauteur : le sélecteur
                // remonte alors juste assez pour tenir dans le panneau. Sa
                // hauteur est mesurée, pas supposée — le calendrier et la liste
                // des projets n'ont pas la même, et elles changent avec leur
                // contenu.
                let y = pickerHeight > 0
                    ? min(button.maxY + 4, max(0, proxy.size.height - pickerHeight))
                    : button.maxY + 4
                ZStack(alignment: .topLeading) {
                    // Un clic à côté referme, comme d'un menu.
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { close() }
                    Group {
                        switch picker {
                        case .date: datePicker
                        case .project: projectPicker
                        }
                    }
                    .frame(width: width)
                    .background(measurePicker)
                    .offset(x: x, y: y)
                }
                .transition(.opacity)
            }
        }
    }

    /// Relève la hauteur du sélecteur ouvert, pour savoir s'il tient dessous.
    private var measurePicker: some View {
        GeometryReader { geometry in
            Color.clear
                .onAppear { pickerHeight = geometry.size.height }
                .onChange(of: geometry.size.height) { _, height in pickerHeight = height }
        }
    }

    /// Une largeur serrée, propre à chaque sélecteur : le calendrier tient dans
    /// sa grille, la liste des projets dans ses noms.
    private static func pickerWidth(_ picker: DraftPicker) -> CGFloat {
        switch picker {
        case .date: return 198
        case .project: return 232
        }
    }

    /// Referme le sélecteur et rend la main au titre.
    private func close() {
        withAnimation(reduceMotion ? nil : Motion.ease(Motion.pageDuration)) {
            draftPicker = nil
        }
        draftFocused = true
    }

    // MARK: - Choisir une date

    private var datePicker: some View {
        VStack(spacing: 6) {
            MonthCalendar(selection: $draftDue)
            if draftDue != nil {
                Button("Retirer la date") {
                    draftDue = nil
                }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .floatingCard()
        .onChange(of: draftDue) { _, date in
            // Une date choisie referme le calendrier : le titre reste ce qu'on
            // est venu écrire.
            guard date != nil else { return }
            close()
        }
    }

    // MARK: - Choisir un projet

    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            SearchField(placeholder: "Chercher un projet…", text: $projectQuery, height: 24)

            if controller.projects.isEmpty {
                Text("Aucun projet accessible. La base Projets est-elle liée ?")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            } else if matchingProjects.isEmpty {
                Text("Aucun projet ne correspond.")
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(matchingProjects) { project in
                            projectRow(project)
                        }
                    }
                }
                // La liste occupe la place qu'elle mérite : la carte ne reste
                // plus à moitié vide quand il n'y a que deux projets.
                .frame(height: min(CGFloat(matchingProjects.count) * 25, 150))
            }

            if draftProject != nil {
                Divider()
                Button("Retirer le projet") { draftProject = nil }
                    .buttonStyle(.plain)
                    .font(Typography.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .floatingCard()
    }

    /// Une ligne de projet : le nom, le survol, et la coche de celui qui est
    /// déjà retenu.
    private func projectRow(_ project: ProjectSummary) -> some View {
        let isChosen = draftProject?.id == project.id
        return Button {
            draftProject = project
            close()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(Typography.caption)
                    .foregroundStyle(isChosen ? AnyShapeStyle(Color.accentColor)
                                             : AnyShapeStyle(.tertiary))
                Text(project.name)
                    .font(Typography.body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(Typography.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background(ofProject: project.id, chosen: isChosen))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            guard !reduceMotion else {
                return hoveredProject = inside ? project.id : (hoveredProject == project.id ? nil : hoveredProject)
            }
            withAnimation(Motion.ease(0.12)) {
                if inside { hoveredProject = project.id }
                else if hoveredProject == project.id { hoveredProject = nil }
            }
        }
    }

    private func background(ofProject id: String, chosen: Bool) -> Color {
        if chosen { return Color.accentColor.opacity(0.12) }
        return hoveredProject == id ? Color.primary.opacity(0.06) : .clear
    }

    /// La recherche porte sur tout ce que la page donne à lire, pas seulement
    /// sur son nom : un projet se retrouve par son client, son statut ou une
    /// note qu'il porte (voir `ProjectDirectory`).
    private var matchingProjects: [ProjectSummary] {
        let needle = TaskCache.fold(projectQuery.trimmingCharacters(in: .whitespaces))
        return controller.projects.filter { $0.matches(needle) }
    }
}

/// Où se trouvent les boutons de la ligne d'écriture, pour y accrocher leur
/// sélecteur. Une position mesurée plutôt que devinée : les boutons se déplacent
/// avec le titre qu'on écrit et la largeur du panneau.
private struct DraftAnchors: PreferenceKey {

    static var defaultValue: [String: Anchor<CGRect>] = [:]

    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, next in next }
    }
}
