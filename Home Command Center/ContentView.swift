import SwiftUI

struct ContentView: View {
    @StateObject private var store = HomeStore()
    @State private var selectedTab: HomeTab = .today
    @AppStorage("hcc.onboarding.completed") private var onboardingCompleted = false
    @State private var showStartupLoading = true

    var body: some View {
        ZStack {
            HomeBackgroundView()
                .ignoresSafeArea()

            if showStartupLoading {
                StartupLoadingView {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showStartupLoading = false
                    }
                }
                .transition(.opacity)
            } else if !onboardingCompleted {
                OnboardingFlowView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        onboardingCompleted = true
                    }
                }
                .transition(.opacity)
            } else {
                appShell
                    .transition(.opacity)
            }
        }
    }

    private var appShell: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selectedTab {
                case .today:
                    TodayView(store: store)
                case .spaces:
                    SpacesView(store: store)
                case .modes:
                    ModesView(store: store)
                case .vault:
                    VaultView(store: store)
                }
            }
            .padding(.bottom, 90)

            CommandTabBar(selectedTab: $selectedTab)
                .padding(.horizontal, 20)
                .padding(.bottom, 14)
        }
    }
}

enum HomeTab: String, CaseIterable {
    case today = "Today"
    case spaces = "Spaces"
    case modes = "Modes"
    case vault = "Vault"

    var icon: String {
        switch self {
        case .today: return "sun.max"
        case .spaces: return "square.grid.2x2"
        case .modes: return "bolt"
        case .vault: return "archivebox"
        }
    }
}

final class HomeStore: ObservableObject {
    @Published private(set) var spaces: [HomeSpace]
    @Published private(set) var items: [HomeItem]
    @Published private(set) var reminders: [HomeReminder]
    @Published private(set) var warranties: [WarrantyCardData]
    @Published private(set) var qrBoxes: [QRLabelBox]

    private let storageKey = "hcc.storage.v1"

    init() {
        if let saved = Self.loadFromStorage(key: storageKey) {
            spaces = saved.spaces
            items = saved.items
            reminders = saved.reminders
            warranties = saved.warranties
            qrBoxes = saved.qrBoxes
        } else {
            let seed = SeedData.make()
            spaces = seed.spaces
            items = seed.items
            reminders = seed.reminders
            warranties = seed.warranties
            qrBoxes = seed.qrBoxes
        }
        recalculateSpaceStats()
    }

    var readyProgress: Double {
        0.82
    }

    var openReminders: [HomeReminder] {
        reminders.filter { !$0.isDone }
    }

    var modePresets: [ModePreset] {
        SeedData.defaultModes
    }

    var manualsCount: Int {
        items.filter { $0.manualSaved }.count
    }

    func items(for spaceName: String) -> [HomeItem] {
        items.filter { $0.space == spaceName }
    }

    func reminders(for spaceName: String) -> [HomeReminder] {
        reminders.filter { !$0.isDone && $0.location == spaceName }
    }

    func addItem(_ draft: ItemDraft) {
        let item = HomeItem(
            name: draft.name,
            space: draft.space,
            category: draft.category,
            reminderType: draft.reminderType,
            repeatEveryDays: draft.repeatEveryDays,
            notes: draft.notes,
            nextDateText: draft.repeatEveryDays > 0 ? "Every \(draft.repeatEveryDays)d" : "No schedule",
            warrantyText: draft.category == .device ? "Warranty pending" : nil,
            manualSaved: false,
            qrAttached: false
        )
        items.insert(item, at: 0)

        if draft.reminderType != .none && draft.repeatEveryDays > 0 {
            let dueText: String
            switch draft.repeatEveryDays {
            case 1:
                dueText = "Today"
            case 2...7:
                dueText = "This week"
            default:
                dueText = "In \(draft.repeatEveryDays) days"
            }

            reminders.insert(
                HomeReminder(
                    title: "\(draft.name)",
                    subtitle: "\(draft.space) · \(draft.reminderType.rawValue)",
                    dueText: dueText,
                    location: draft.space,
                    isDone: false
                ),
                at: 0
            )
        }

        recalculateSpaceStats()
        save()
    }

    func completeReminder(_ reminderID: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == reminderID }) else { return }
        reminders[idx].isDone = true
        recalculateSpaceStats()
        save()
    }

    func snoozeReminder(_ reminderID: UUID) {
        guard let idx = reminders.firstIndex(where: { $0.id == reminderID }) else { return }
        reminders[idx].dueText = "Tomorrow"
        recalculateSpaceStats()
        save()
    }

    func addWarrantyReminder(for card: WarrantyCardData) {
        reminders.insert(
            HomeReminder(
                title: card.title,
                subtitle: "Warranty · \(card.title)",
                dueText: "This month",
                location: "Vault",
                isDone: false
            ),
            at: 0
        )
        recalculateSpaceStats()
        save()
    }

    func addSpace(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !spaces.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }

        spaces.append(
            HomeSpace(
                name: trimmed,
                itemCount: 0,
                activeReminders: 0,
                tasksSummary: "All good",
                icons: defaultIcons(for: trimmed)
            )
        )
        recalculateSpaceStats()
        save()
    }

    func addWarranty(title: String, space: String, warrantyEnds: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        warranties.insert(
            WarrantyCardData(
                title: trimmed,
                space: space.isEmpty ? "Home" : space,
                warrantyEnds: warrantyEnds.isEmpty ? "TBD" : warrantyEnds
            ),
            at: 0
        )
        save()
    }

    func addQRLabel(code: String, content: String, location: String) {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLocation = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCode.isEmpty else { return }

        qrBoxes.insert(
            QRLabelBox(
                code: normalizedCode,
                content: normalizedContent.isEmpty ? "Unsorted" : normalizedContent,
                location: normalizedLocation.isEmpty ? "Storage" : normalizedLocation
            ),
            at: 0
        )
        save()
    }

    private func recalculateSpaceStats() {
        for index in spaces.indices {
            let spaceName = spaces[index].name
            let itemCount = items.filter { $0.space == spaceName }.count
            let activeReminderCount = reminders.filter { !$0.isDone && $0.location == spaceName }.count

            let summary: String
            if activeReminderCount == 0 {
                summary = "All good"
            } else if activeReminderCount == 1 {
                summary = "1 task"
            } else {
                summary = "\(activeReminderCount) tasks"
            }

            spaces[index].itemCount = itemCount
            spaces[index].activeReminders = activeReminderCount
            spaces[index].tasksSummary = summary
        }
    }

    private func defaultIcons(for spaceName: String) -> [String] {
        let name = spaceName.lowercased()
        if name.contains("kitchen") { return ["fork.knife", "drop", "wrench.and.screwdriver"] }
        if name.contains("bath") { return ["drop", "sparkles", "cross.case"] }
        if name.contains("bed") { return ["bed.double", "leaf", "doc.text"] }
        if name.contains("hall") { return ["figure.walk", "lightbulb", "doc.text"] }
        if name.contains("storage") { return ["archivebox", "shippingbox", "qrcode"] }
        if name.contains("balcony") { return ["leaf", "sun.max", "drop"] }
        return ["square.grid.2x2", "wrench.and.screwdriver", "doc.text"]
    }

    func modeSteps(for mode: ModePreset, arrival: String, selectedAreas: Set<String>, selectedTime: String) -> [PlanStep] {
        let trimmedAreas = selectedAreas.isEmpty ? ["Home"] : Array(selectedAreas)
        let areaText = trimmedAreas.joined(separator: ", ")
        let timeScale: Double
        switch selectedTime {
        case "15 min":
            timeScale = 0.65
        case "30 min":
            timeScale = 0.85
        case "1 hour":
            timeScale = 1.1
        default:
            timeScale = 1.25
        }

        let arrivalHint: String
        switch arrival {
        case "Today":
            arrivalHint = "Prioritize quick wins"
        case "Tomorrow":
            arrivalHint = "Balance prep and detail"
        default:
            arrivalHint = "Use full checklist"
        }

        return mode.steps.enumerated().map { index, step in
            let adjustedMinutes = max(3, Int(Double(step.minutes) * timeScale))
            let decoratedDetail: String
            if index == 0 {
                decoratedDetail = "\(step.detail) · \(arrivalHint)"
            } else {
                decoratedDetail = "\(step.detail) · Focus: \(areaText)"
            }
            return PlanStep(title: step.title, detail: decoratedDetail, minutes: adjustedMinutes)
        }
    }

    private func save() {
        let snapshot = StoreSnapshot(
            spaces: spaces,
            items: items,
            reminders: reminders,
            warranties: warranties,
            qrBoxes: qrBoxes
        )

        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private static func loadFromStorage(key: String) -> StoreSnapshot? {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let snapshot = try? JSONDecoder().decode(StoreSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }
}

private struct TodayView: View {
    @ObservedObject var store: HomeStore
    @State private var showQuickAdd = false
    @State private var selectedPreset: ModePreset?
    @State private var showModeBuilder = false
    @State private var showReviewMessage = false

    private let roomGridColumns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    private let horizontalCardWidth = UIScreen.main.bounds.width - 56

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(spacing: 20) {
                    header
                    StatusHeroCard(progress: store.readyProgress) {
                        showReviewMessage = true
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Start a Mode")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkBlack)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(store.modePresets.prefix(4)) { preset in
                                    ModeCard(mode: preset)
                                        .frame(width: horizontalCardWidth)
                                        .onTapGesture {
                                            selectedPreset = preset
                                            showModeBuilder = true
                                        }
                                }
                            }
                            .padding(.horizontal, 2)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Coming Up")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkBlack)

                        ForEach(Array(store.openReminders.prefix(3))) { reminder in
                            ReminderCard(
                                reminder: reminder,
                                onDone: { store.completeReminder(reminder.id) },
                                onSnooze: { store.snoozeReminder(reminder.id) }
                            )
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Rooms")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkBlack)

                        LazyVGrid(columns: roomGridColumns, spacing: 12) {
                            ForEach(Array(store.spaces.prefix(4))) { space in
                                NavigationLink {
                                    SpaceDetailView(store: store, space: space)
                                } label: {
                                    SpaceSnapshotCard(space: space)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
            .sheet(isPresented: $showQuickAdd) {
                QuickAddSheet(store: store) { preset in
                    selectedPreset = preset
                    showModeBuilder = true
                }
                    .presentationDetents([.medium, .large])
            }
            .navigationDestination(isPresented: $showModeBuilder) {
                if let preset = selectedPreset {
                    ModeBuilderView(store: store, mode: preset)
                } else {
                    EmptyView()
                }
            }
            .alert("Home review", isPresented: $showReviewMessage) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Everything is under control. Focus on filters, plants, and expiring warranties.")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Good morning")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.mutedGray)
                Text("Your home is 82% ready")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)
            }
            Spacer(minLength: 12)
            FloatingAddButton {
                showQuickAdd = true
            }
        }
    }
}

private struct QuickAddSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HomeStore
    let onStartMode: (ModePreset) -> Void
    @State private var showAddItem = false
    @State private var showAddWarranty = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Quick Add")
                .font(.system(size: 26, weight: .bold, design: .rounded))

            quickRow(title: "Add Item", subtitle: "Create a new home item") {
                showAddItem = true
            }

            quickRow(title: "Add Reminder", subtitle: "Create a follow-up on Today") {
                let draft = ItemDraft(
                    name: "Quick Reminder",
                    space: "Kitchen",
                    category: .other,
                    reminderType: .maintenance,
                    repeatEveryDays: 3,
                    notes: "Added from quick add"
                )
                store.addItem(draft)
                dismiss()
            }

            quickRow(title: "Add Document", subtitle: "Store a manual or warranty") {
                showAddWarranty = true
            }

            quickRow(title: "Start Mode", subtitle: "Generate a plan in 3 steps") {
                if let preset = store.modePresets.first {
                    onStartMode(preset)
                }
                dismiss()
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .sheet(isPresented: $showAddItem) {
            AddHomeItemView(store: store)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showAddWarranty) {
            AddWarrantyView(store: store)
                .presentationDetents([.large])
        }
    }

    private func quickRow(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.inkBlack)
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Color.mutedGray)
            }
            .padding(14)
            .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 10, y: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct SpacesView: View {
    @ObservedObject var store: HomeStore
    @State private var selectedFilter: SpaceFilter = .all
    @State private var showAddSpace = false

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Spaces")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.inkBlack)
                            Text("Everything in your home, organized by room")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.mutedGray)
                        }
                        Spacer()
                        PrimaryButton(title: "Add Space") {
                            showAddSpace = true
                        }
                        .frame(width: 120)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(SpaceFilter.allCases) { filter in
                                FilterChip(title: filter.rawValue, isSelected: selectedFilter == filter) {
                                    selectedFilter = filter
                                }
                            }
                        }
                    }

                    LazyVStack(spacing: 12) {
                        ForEach(filteredSpaces) { space in
                            NavigationLink {
                                SpaceDetailView(store: store, space: space)
                            } label: {
                                SpaceCard(space: space)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .sheet(isPresented: $showAddSpace) {
                AddSpaceView(store: store)
            }
        }
    }

    private var filteredSpaces: [HomeSpace] {
        switch selectedFilter {
        case .all:
            return store.spaces
        case .rooms:
            return store.spaces.filter { !$0.name.contains("Storage") && !$0.name.contains("Balcony") }
        case .storage:
            return store.spaces.filter { $0.name.contains("Storage") }
        case .plants:
            return store.spaces.filter { space in
                store.items(for: space.name).contains(where: { $0.category == .plant }) || space.icons.contains("leaf")
            }
        case .devices:
            return store.spaces.filter { space in
                store.items(for: space.name).contains(where: { $0.category == .device || $0.category == .tool })
            }
        case .documents:
            return store.spaces.filter { space in
                store.items(for: space.name).contains(where: { $0.category == .document }) || space.icons.contains("doc.text")
            }
        }
    }
}

private struct SpaceDetailView: View {
    @ObservedObject var store: HomeStore
    let space: HomeSpace
    @State private var showAddItem = false

    var body: some View {
        ScreenScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text(space.name)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.cardWhite)
                    .frame(height: 145)
                    .overlay(alignment: .leading) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("\(space.name) Health")
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                            Text("\(max(store.reminders(for: space.name).count, 1)) things need attention")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.mutedGray)
                        }
                        .padding(18)
                    }
                    .shadow(color: .black.opacity(0.08), radius: 12, y: 6)

                Text("Items")
                    .font(.system(size: 20, weight: .bold, design: .rounded))

                ForEach(store.items(for: space.name)) { item in
                    itemCard(item)
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add Item") {
                    showAddItem = true
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            }
        }
        .sheet(isPresented: $showAddItem) {
            AddHomeItemView(store: store, defaultSpace: space.name)
        }
    }

    private func itemCard(_ item: HomeItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.name)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text(item.nextDateText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
            if let warrantyText = item.warrantyText {
                Text(warrantyText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.accentPurple)
            }
            HStack(spacing: 8) {
                tag(item.category.rawValue)
                if item.manualSaved { tag("Manual saved") }
                if item.qrAttached { tag("QR label attached") }
            }
        }
        .padding(14)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 9, y: 6)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.backgroundSand.opacity(0.8), in: Capsule())
    }
}

private struct AddHomeItemView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HomeStore

    @State private var name: String = ""
    @State private var selectedSpace: String = "Kitchen"
    @State private var selectedCategory: ItemCategory = .device
    @State private var selectedReminder: ReminderType = .maintenance
    @State private var repeatEvery: String = "30"
    @State private var notes: String = ""

    let defaultSpace: String?

    init(store: HomeStore, defaultSpace: String? = nil) {
        self.store = store
        self.defaultSpace = defaultSpace
    }

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Add Home Item")
                        .font(.system(size: 30, weight: .bold, design: .rounded))

                    fieldTitle("Item Name")
                    TextField("Water Filter", text: $name)
                        .textFieldStyle(.roundedBorder)

                    fieldTitle("Space")
                    chipsGrid(store.spaces.map(\.name), selected: selectedSpace) { selectedSpace = $0 }

                    fieldTitle("Category")
                    chipsGrid(ItemCategory.allCases.map(\.rawValue), selected: selectedCategory.rawValue) {
                        selectedCategory = ItemCategory(rawValue: $0) ?? .other
                    }

                    fieldTitle("Reminder Type")
                    chipsGrid(ReminderType.allCases.map(\.rawValue), selected: selectedReminder.rawValue) {
                        selectedReminder = ReminderType(rawValue: $0) ?? .none
                    }

                    fieldTitle("Repeat Every")
                    TextField("30", text: $repeatEvery)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)

                    fieldTitle("Notes")
                    TextField("Optional notes", text: $notes, axis: .vertical)
                        .textFieldStyle(.roundedBorder)

                    PrimaryButton(title: "Save Item") {
                        let draft = ItemDraft(
                            name: name.isEmpty ? "New Item" : name,
                            space: selectedSpace,
                            category: selectedCategory,
                            reminderType: selectedReminder,
                            repeatEveryDays: Int(repeatEvery) ?? 0,
                            notes: notes
                        )
                        store.addItem(draft)
                        dismiss()
                    }
                }
                .padding(20)
            }
            .onAppear {
                if let defaultSpace {
                    selectedSpace = defaultSpace
                }
            }
        }
    }

    private func fieldTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.mutedGray)
    }

    private func chipsGrid(_ values: [String], selected: String, action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            ForEach(values, id: \.self) { value in
                FilterChip(title: value, isSelected: value == selected) {
                    action(value)
                }
            }
        }
    }
}

private struct AddSpaceView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HomeStore
    @State private var spaceName = ""
    private var canSave: Bool { !spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Add Space")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Create a new room or area for your home setup.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)

                    TextField("Laundry Room", text: $spaceName)
                        .textFieldStyle(.roundedBorder)

                    PrimaryButton(title: "Save Space") {
                        guard canSave else { return }
                        store.addSpace(name: spaceName)
                        dismiss()
                    }
                    .opacity(canSave ? 1 : 0.6)
                }
                .padding(20)
            }
        }
    }
}

private struct AddWarrantyView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HomeStore
    @State private var title = ""
    @State private var selectedSpace = "Kitchen"
    @State private var warrantyEnds = ""
    private var canSave: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Add Warranty")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Store device warranty metadata for quick access in Vault.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)

                    TextField("Device Name", text: $title)
                        .textFieldStyle(.roundedBorder)

                    Text("Space")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.mutedGray)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(store.spaces.map(\.name), id: \.self) { spaceName in
                            FilterChip(title: spaceName, isSelected: selectedSpace == spaceName) {
                                selectedSpace = spaceName
                            }
                        }
                    }

                    TextField("Warranty ends (e.g. Sep 2027)", text: $warrantyEnds)
                        .textFieldStyle(.roundedBorder)

                    PrimaryButton(title: "Save Warranty") {
                        guard canSave else { return }
                        store.addWarranty(title: title, space: selectedSpace, warrantyEnds: warrantyEnds)
                        dismiss()
                    }
                    .opacity(canSave ? 1 : 0.6)
                }
                .padding(20)
            }
        }
    }
}

private struct AddQRLabelView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: HomeStore
    @State private var code = ""
    @State private var content = ""
    @State private var location = ""
    private var canSave: Bool { !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Create QR Label")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Add a box label with content and location for fast retrieval.")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)

                    TextField("Box D17", text: $code)
                        .textFieldStyle(.roundedBorder)
                    TextField("Seasonal decorations", text: $content)
                        .textFieldStyle(.roundedBorder)
                    TextField("Storage room", text: $location)
                        .textFieldStyle(.roundedBorder)

                    PrimaryButton(title: "Save QR Label") {
                        guard canSave else { return }
                        store.addQRLabel(code: code, content: content, location: location)
                        dismiss()
                    }
                    .opacity(canSave ? 1 : 0.6)
                }
                .padding(20)
            }
        }
    }
}

private struct ModesView: View {
    @ObservedObject var store: HomeStore

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Modes")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkBlack)

                    Text("Generate a plan for any home situation")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)

                    LazyVStack(spacing: 12) {
                        ForEach(store.modePresets) { mode in
                            NavigationLink {
                                ModeBuilderView(store: store, mode: mode)
                            } label: {
                                ModeCard(mode: mode)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
        }
    }
}

private struct ModeBuilderView: View {
    @ObservedObject var store: HomeStore
    let mode: ModePreset

    @State private var arrival: String = "Today"
    @State private var selectedAreas: Set<String> = ["Living Room", "Bathroom"]
    @State private var selectedTime: String = "30 min"
    @State private var showGeneratedPlan = false
    @State private var generatedSteps: [PlanStep] = []

    private let arrivalOptions = ["Today", "Tomorrow", "This week"]
    private let areaOptions = ["Living Room", "Bathroom", "Kitchen", "Guest Room", "Entryway"]
    private let timeOptions = ["15 min", "30 min", "1 hour", "Full prep"]

    var body: some View {
        ScreenScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text(mode.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)

                StepCard(title: "When are they arriving?") {
                    optionRow(values: arrivalOptions, selected: arrival) {
                        arrival = $0
                    }
                }

                StepCard(title: "Which areas matter?") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
                        ForEach(areaOptions, id: \.self) { area in
                            FilterChip(title: area, isSelected: selectedAreas.contains(area)) {
                                if selectedAreas.contains(area) {
                                    selectedAreas.remove(area)
                                } else {
                                    selectedAreas.insert(area)
                                }
                            }
                        }
                    }
                }

                StepCard(title: "How much time do you have?") {
                    optionRow(values: timeOptions, selected: selectedTime) {
                        selectedTime = $0
                    }
                }

                PrimaryButton(title: "Generate Plan") {
                    generatedSteps = store.modeSteps(
                        for: mode,
                        arrival: arrival,
                        selectedAreas: selectedAreas,
                        selectedTime: selectedTime
                    )
                    showGeneratedPlan = true
                }
                .padding(.top, 8)
            }
            .padding(20)
        }
        .navigationDestination(isPresented: $showGeneratedPlan) {
            GeneratedPlanView(
                modeTitle: mode.title,
                timeLabel: selectedTime,
                steps: generatedSteps.isEmpty ? mode.steps : generatedSteps
            )
        }
    }

    private func optionRow(values: [String], selected: String, action: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 10)], spacing: 10) {
            ForEach(values, id: \.self) { value in
                FilterChip(title: value, isSelected: value == selected) {
                    action(value)
                }
            }
        }
    }
}

private struct GeneratedPlanView: View {
    let modeTitle: String
    let timeLabel: String
    let steps: [PlanStep]
    @State private var showExecution = false
    @State private var showTemplateSaved = false

    var totalMinutes: Int {
        steps.reduce(0) { $0 + $1.minutes }
    }

    var body: some View {
        ScreenScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("Your Home Plan")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(modeTitle) Plan")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("\(steps.count) steps · \(totalMinutes) min")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 6)

                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    GeneratedStepCard(index: index + 1, step: step)
                }

                PrimaryButton(title: "Start Plan") {
                    showExecution = true
                }

                PrimaryButton(title: "Save as Template", style: .secondary) {
                    showTemplateSaved = true
                }
            }
            .padding(20)
        }
        .navigationDestination(isPresented: $showExecution) {
            ActivePlanView(modeTitle: modeTitle, steps: steps)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(timeLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.mutedGray)
            }
        }
        .alert("Template saved", isPresented: $showTemplateSaved) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This plan template is available in Modes for future runs.")
        }
    }
}

private struct ActivePlanView: View {
    let modeTitle: String
    let steps: [PlanStep]

    @State private var currentStepIndex: Int = 0
    @State private var isPaused = false

    var progress: Double {
        guard !steps.isEmpty else { return 1 }
        return Double(currentStepIndex) / Double(steps.count)
    }

    var body: some View {
        ScreenScrollView {
            LazyVStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        ProgressRingView(progress: progress)
                            .frame(width: 72, height: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(modeTitle)
                                .font(.system(size: 20, weight: .bold, design: .rounded))
                            Text("Step \(min(currentStepIndex + 1, steps.count)) of \(steps.count)")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.mutedGray)
                        }
                        Spacer()
                    }

                    if let step = currentStep {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.title)
                                .font(.system(size: 19, weight: .semibold, design: .rounded))
                            Text("\(step.minutes) min · \(step.detail)")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.mutedGray)
                        }
                    }
                }
                .padding(18)
                .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 6)

                HStack(spacing: 10) {
                    PrimaryButton(title: "Done") {
                        guard !isPaused else { return }
                        guard currentStepIndex < steps.count else { return }
                        currentStepIndex += 1
                    }
                    PrimaryButton(title: "Skip", style: .secondary) {
                        guard !isPaused else { return }
                        guard currentStepIndex < steps.count else { return }
                        currentStepIndex += 1
                    }
                    PrimaryButton(title: isPaused ? "Resume" : "Pause", style: .secondary) {
                        isPaused.toggle()
                    }
                }

                if currentStepIndex >= steps.count {
                    Text("Plan complete. Home secured.")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentGreen)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }
            }
            .padding(20)
        }
        .navigationTitle("Plan in Progress")
    }

    private var currentStep: PlanStep? {
        guard currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }
}

private struct VaultView: View {
    @ObservedObject var store: HomeStore
    @State private var showAddWarranty = false
    @State private var showAddQR = false
    @State private var selectedWarranty: WarrantyCardData?
    @State private var showWarrantyDetail = false

    var body: some View {
        NavigationStack {
            ScreenScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Vault")
                                .font(.system(size: 32, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.inkBlack)
                            Text("Documents, warranties and labels in one place")
                                .font(.system(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.mutedGray)
                        }
                        Spacer()
                        PrimaryButton(title: "Scan") {
                            showAddWarranty = true
                        }
                            .frame(width: 88)
                    }

                    LazyVStack(spacing: 10) {
                        VaultCard(title: "Warranties", subtitle: "\(store.warranties.count) saved · 2 expiring soon", icon: "shield.lefthalf.filled")
                        VaultCard(title: "Manuals", subtitle: "\(store.manualsCount) documents", icon: "doc.text")
                        VaultCard(title: "QR Labels", subtitle: "\(store.qrBoxes.count) labels created", icon: "qrcode")
                    }

                    ForEach(store.warranties) { warranty in
                        warrantyCard(warranty) {
                            selectedWarranty = warranty
                            showWarrantyDetail = true
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Storage Boxes")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.inkBlack)

                        ForEach(store.qrBoxes) { box in
                            HStack {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(box.code)
                                        .font(.system(size: 17, weight: .bold, design: .rounded))
                                    Text("\(box.content) · \(box.location)")
                                        .font(.system(size: 13, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.mutedGray)
                                }
                                Spacer()
                                Image(systemName: "qrcode")
                                    .foregroundStyle(Color.accentPurple)
                            }
                            .padding(14)
                            .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.05), radius: 9, y: 6)
                        }

                        PrimaryButton(title: "Create QR Label", style: .secondary) {
                            showAddQR = true
                        }
                    }
                }
                .padding(20)
            }
            .sheet(isPresented: $showAddWarranty) {
                AddWarrantyView(store: store)
            }
            .sheet(isPresented: $showAddQR) {
                AddQRLabelView(store: store)
            }
            .navigationDestination(isPresented: $showWarrantyDetail) {
                if let warranty = selectedWarranty {
                    DocumentDetailView(warranty: warranty)
                } else {
                    EmptyView()
                }
            }
        }
    }

    private func warrantyCard(_ card: WarrantyCardData, onOpen: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(card.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text("Warranty ends: \(card.warrantyEnds)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
            Text("Manual attached")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentPurple)
            HStack(spacing: 10) {
                PrimaryButton(title: "Open", style: .secondary) {
                    onOpen()
                }
                PrimaryButton(title: "Set Reminder") {
                    store.addWarrantyReminder(for: card)
                }
            }
        }
        .padding(16)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 6)
    }
}

private struct DocumentDetailView: View {
    let warranty: WarrantyCardData
    @State private var actionMessage = ""
    @State private var showActionAlert = false

    var body: some View {
        ScreenScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                Text("\(warranty.title) Manual")
                    .font(.system(size: 28, weight: .bold, design: .rounded))

                detailRow(label: "Linked Item", value: warranty.title)
                detailRow(label: "Space", value: warranty.space)
                detailRow(label: "Type", value: "Manual")
                detailRow(label: "Reminder", value: "Descale every 30 days")

                LazyVStack(spacing: 10) {
                    PrimaryButton(title: "Open File", style: .secondary) {
                        actionMessage = "\(warranty.title) manual opened."
                        showActionAlert = true
                    }
                    PrimaryButton(title: "Replace File", style: .secondary) {
                        actionMessage = "You can attach a new file in the next iteration."
                        showActionAlert = true
                    }
                    PrimaryButton(title: "Share", style: .secondary) {
                        actionMessage = "Sharing flow is ready to connect to system share sheet."
                        showActionAlert = true
                    }
                }
            }
            .padding(20)
        }
        .alert("Document Action", isPresented: $showActionAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionMessage)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.mutedGray)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 5)
    }
}

private struct StartupLoadingView: View {
    let onFinished: () -> Void

    @State private var phraseIndex = 0
    @State private var progress = 0.08
    @State private var didStart = false

    private let phrases = [
        "Preparing your dashboard",
        "Loading rooms and reminders",
        "Getting today ready"
    ]

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 16) {
                ProgressRingView(progress: progress)
                    .frame(width: 94, height: 94)

                Text(phrases[phraseIndex])
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                Text("Almost ready")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.mutedGray)

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.cardWhite.opacity(0.55))
                            .frame(height: 10)
                        Capsule()
                            .fill(Color.inkBlack.opacity(0.82))
                            .frame(width: proxy.size.width * progress, height: 10)
                    }
                }
                .frame(height: 10)
            }
            .padding(22)
            .frame(maxWidth: .infinity)
            .background(Color.cardWhite.opacity(0.9), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 7)
            .padding(.horizontal, 24)

            Spacer()
        }
        .task {
            guard !didStart else { return }
            didStart = true

            for index in phrases.indices {
                withAnimation(.easeInOut(duration: 0.35)) {
                    phraseIndex = index
                    progress = min(0.85, 0.25 + (Double(index) * 0.25))
                }
                try? await Task.sleep(nanoseconds: 650_000_000)
            }

            withAnimation(.easeInOut(duration: 0.35)) {
                progress = 1.0
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            onFinished()
        }
    }
}

private struct OnboardingFlowView: View {
    let onFinish: () -> Void
    @State private var pageIndex = 0

    private let pages: [OnboardingPage] = [
        OnboardingPage(
            icon: "sun.max",
            title: "Start with clarity",
            subtitle: "See what matters today in one calm dashboard."
        ),
        OnboardingPage(
            icon: "square.grid.2x2",
            title: "Keep spaces organized",
            subtitle: "Track rooms, items, reminders, and documents without clutter."
        ),
        OnboardingPage(
            icon: "bolt",
            title: "Run fast home modes",
            subtitle: "Answer a few prompts and get a ready-to-use action plan."
        )
    ]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: pages[pageIndex].icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.accentPurple)
                        .frame(width: 40, height: 40)
                        .background(Color.softBlue.opacity(0.25), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    Spacer()
                    Button(pageIndex == pages.count - 1 ? "Close" : "Skip") {
                        onFinish()
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.mutedGray)
                }

                Text(pages[pageIndex].title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)

                Text(pages[pageIndex].subtitle)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.mutedGray)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    ForEach(pages.indices, id: \.self) { index in
                        Capsule()
                            .fill(index == pageIndex ? Color.inkBlack : Color.inkBlack.opacity(0.16))
                            .frame(width: index == pageIndex ? 30 : 10, height: 10)
                    }
                }
                .padding(.top, 4)

                PrimaryButton(title: pageIndex == pages.count - 1 ? "Get Started" : "Next") {
                    if pageIndex < pages.count - 1 {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                            pageIndex += 1
                        }
                    } else {
                        onFinish()
                    }
                }
                .padding(.top, 6)
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardWhite.opacity(0.93), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
            .padding(.horizontal, 20)

            Spacer()
        }
    }
}

private struct OnboardingPage {
    let icon: String
    let title: String
    let subtitle: String
}

private struct ScreenScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            content
        }
        .background(
            Color.backgroundSand.opacity(0.42)
                .ignoresSafeArea(edges: .top)
        )
    }
}

private struct StepCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
            content
        }
        .padding(16)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 5)
    }
}

struct HomeBackgroundView: View {
    var body: some View {
        LinearGradient(
            colors: [Color.backgroundCream, Color.backgroundSand, Color.softBlue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(Color.black.opacity(0.22))
        .overlay {
            GeometryReader { proxy in
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: proxy.size.width * 0.8)
                        .blur(radius: 16)
                        .offset(x: -80, y: -180)

                    Circle()
                        .fill(Color.softBlue.opacity(0.14))
                        .frame(width: proxy.size.width * 0.9)
                        .blur(radius: 20)
                        .offset(x: 90, y: 260)
                }
            }
        }
    }
}

struct CommandTabBar: View {
    @Binding var selectedTab: HomeTab

    var body: some View {
        HStack(spacing: 8) {
            ForEach(HomeTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 16, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.inkBlack : Color.mutedGray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(selectedTab == tab ? Color.white.opacity(0.7) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 12, y: 6)
    }
}

struct StatusHeroCard: View {
    let progress: Double
    let onReview: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Home Status")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.inkBlack)
                    Text("Stable and ready")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.mutedGray)
                }
                Spacer()
                ProgressRingView(progress: progress)
                    .frame(width: 80, height: 80)
            }

            VStack(spacing: 8) {
                miniIndicator(title: "Air filters", subtitle: "Due in 4 days", icon: "wind")
                miniIndicator(title: "Plants", subtitle: "2 need water", icon: "leaf")
                miniIndicator(title: "Documents", subtitle: "3 warranties expire soon", icon: "doc.text")
            }

            PrimaryButton(title: "Review Home", style: .secondary) {
                onReview()
            }
        }
        .padding(18)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 14, y: 8)
    }

    private func miniIndicator(title: String, subtitle: String, icon: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(Color.accentOrange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)
                Text(subtitle)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.mutedGray)
            }
            Spacer()
        }
    }
}

struct ModeCard: View {
    let mode: ModePreset

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(mode.title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text(mode.subtitle)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
            Spacer(minLength: 8)
            Text("Generate")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.accentGreen.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentGreen)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 9, y: 6)
    }
}

struct SpaceCard: View {
    let space: HomeSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(space.name)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text("\(space.itemCount) items")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
            Text("\(space.activeReminders) active reminders")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.accentOrange)

            HStack(spacing: 8) {
                ForEach(space.icons, id: \.self) { icon in
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.accentPurple)
                        .padding(6)
                        .background(Color.softBlue.opacity(0.25), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 5)
    }
}

private struct SpaceSnapshotCard: View {
    let space: HomeSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(space.name)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text("\(space.itemCount) items · \(space.tasksSummary)")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 5)
    }
}

struct ReminderCard: View {
    let reminder: HomeReminder
    let onDone: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(reminder.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text("\(reminder.subtitle) · \(reminder.dueText)")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
            HStack(spacing: 10) {
                PrimaryButton(title: "Done", style: .secondary, action: onDone)
                PrimaryButton(title: "Snooze", style: .secondary, action: onSnooze)
            }
        }
        .padding(16)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 10, y: 6)
    }
}

struct VaultCard: View {
    let title: String
    let subtitle: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentPurple)
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Color.mutedGray)
                .lineLimit(2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 5)
    }
}

struct ProgressRingView: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.backgroundSand, lineWidth: 10)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(
                    AngularGradient(colors: [Color.accentGreen, Color.accentOrange], center: .center),
                    style: StrokeStyle(lineWidth: 10, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
            Text("\(Int(progress * 100))%")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.inkBlack)
        }
    }
}

struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? Color.inkBlack : Color.mutedGray)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? Color.white.opacity(0.8) : Color.white.opacity(0.45))
                )
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryButton: View {
    enum ButtonStyleType {
        case primary
        case secondary
    }

    let title: String
    var style: ButtonStyleType = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(style == .primary ? Color.white : Color.inkBlack)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(style == .primary ? Color.inkBlack : Color.backgroundSand)
                )
        }
        .buttonStyle(.plain)
    }
}

struct FloatingAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.white)
                .frame(width: 46, height: 46)
                .background(Color.inkBlack, in: Circle())
                .shadow(color: .black.opacity(0.15), radius: 9, y: 5)
        }
        .buttonStyle(.plain)
    }
}

struct GeneratedStepCard: View {
    let index: Int
    let step: PlanStep

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white)
                .frame(width: 28, height: 28)
                .background(Color.inkBlack, in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(step.title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.inkBlack)
                Text("\(step.minutes) min · \(step.detail)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.mutedGray)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.cardWhite, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 5)
    }
}

struct StoreSnapshot: Codable {
    var spaces: [HomeSpace]
    var items: [HomeItem]
    var reminders: [HomeReminder]
    var warranties: [WarrantyCardData]
    var qrBoxes: [QRLabelBox]
}

struct HomeSpace: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var itemCount: Int
    var activeReminders: Int
    var tasksSummary: String
    var icons: [String]
}

struct HomeItem: Identifiable, Codable, Hashable {
    var id = UUID()
    let name: String
    let space: String
    let category: ItemCategory
    let reminderType: ReminderType
    let repeatEveryDays: Int
    let notes: String
    let nextDateText: String
    let warrantyText: String?
    let manualSaved: Bool
    let qrAttached: Bool
}

struct HomeReminder: Identifiable, Codable, Hashable {
    var id = UUID()
    let title: String
    let subtitle: String
    var dueText: String
    let location: String
    var isDone: Bool
}

struct WarrantyCardData: Identifiable, Codable, Hashable {
    var id = UUID()
    let title: String
    let space: String
    let warrantyEnds: String
}

struct QRLabelBox: Identifiable, Codable, Hashable {
    var id = UUID()
    let code: String
    let content: String
    let location: String
}

struct ModePreset: Identifiable, Hashable {
    var id = UUID()
    let title: String
    let subtitle: String
    let steps: [PlanStep]
}

struct PlanStep: Identifiable, Hashable {
    var id = UUID()
    let title: String
    let detail: String
    let minutes: Int
}

struct ItemDraft {
    let name: String
    let space: String
    let category: ItemCategory
    let reminderType: ReminderType
    let repeatEveryDays: Int
    let notes: String
}

enum ItemCategory: String, CaseIterable, Codable {
    case device = "Device"
    case tool = "Tool"
    case plant = "Plant"
    case document = "Document"
    case cleaning = "Cleaning"
    case storageBox = "Storage Box"
    case safety = "Safety"
    case other = "Other"
}

enum ReminderType: String, CaseIterable, Codable {
    case none = "None"
    case maintenance = "Maintenance"
    case watering = "Watering"
    case warranty = "Warranty"
}

enum SpaceFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case rooms = "Rooms"
    case storage = "Storage"
    case plants = "Plants"
    case devices = "Devices"
    case documents = "Documents"

    var id: String { rawValue }
}

enum SeedData {
    static func make() -> StoreSnapshot {
        StoreSnapshot(
            spaces: [
                HomeSpace(name: "Kitchen", itemCount: 18, activeReminders: 3, tasksSummary: "3 tasks", icons: ["refrigerator", "drop", "wrench.and.screwdriver", "doc.text"]),
                HomeSpace(name: "Living Room", itemCount: 10, activeReminders: 1, tasksSummary: "1 task", icons: ["sofa", "tv", "doc.text"]),
                HomeSpace(name: "Bathroom", itemCount: 9, activeReminders: 2, tasksSummary: "2 tasks", icons: ["drop", "sparkles", "cross.case"]),
                HomeSpace(name: "Bedroom", itemCount: 8, activeReminders: 0, tasksSummary: "All good", icons: ["bed.double", "leaf", "doc.text"]),
                HomeSpace(name: "Hallway", itemCount: 6, activeReminders: 1, tasksSummary: "1 task", icons: ["figure.walk", "lightbulb", "doc.text"]),
                HomeSpace(name: "Storage", itemCount: 24, activeReminders: 4, tasksSummary: "Needs sorting", icons: ["archivebox", "shippingbox", "qrcode"]),
                HomeSpace(name: "Balcony", itemCount: 5, activeReminders: 1, tasksSummary: "1 task", icons: ["leaf", "sun.max", "drop"])
            ],
            items: [
                HomeItem(name: "Water Filter", space: "Kitchen", category: .device, reminderType: .maintenance, repeatEveryDays: 30, notes: "Replace every 30 days", nextDateText: "Next: May 22", warrantyText: nil, manualSaved: true, qrAttached: false),
                HomeItem(name: "Coffee Machine", space: "Kitchen", category: .device, reminderType: .maintenance, repeatEveryDays: 30, notes: "Descale monthly", nextDateText: "Warranty until Dec 2026", warrantyText: "Warranty until Dec 2026", manualSaved: true, qrAttached: false),
                HomeItem(name: "Cleaning Kit", space: "Kitchen", category: .cleaning, reminderType: .none, repeatEveryDays: 0, notes: "Stored under sink", nextDateText: "Stored under sink", warrantyText: nil, manualSaved: false, qrAttached: true),
                HomeItem(name: "Bedroom Plant", space: "Bedroom", category: .plant, reminderType: .watering, repeatEveryDays: 4, notes: "Low light plant", nextDateText: "Water in 2 days", warrantyText: nil, manualSaved: false, qrAttached: false)
            ],
            reminders: [
                HomeReminder(title: "Replace water filter", subtitle: "Kitchen", dueText: "Due tomorrow", location: "Kitchen", isDone: false),
                HomeReminder(title: "Water bedroom plants", subtitle: "Bedroom", dueText: "Today", location: "Bedroom", isDone: false),
                HomeReminder(title: "Check smoke detector", subtitle: "Hallway", dueText: "This week", location: "Hallway", isDone: false)
            ],
            warranties: [
                WarrantyCardData(title: "Washing Machine", space: "Bathroom", warrantyEnds: "Sep 2027"),
                WarrantyCardData(title: "Coffee Machine", space: "Kitchen", warrantyEnds: "Dec 2026")
            ],
            qrBoxes: [
                QRLabelBox(code: "Box A12", content: "Winter clothes", location: "Storage room"),
                QRLabelBox(code: "Box B04", content: "Cables and chargers", location: "Hallway"),
                QRLabelBox(code: "Box C02", content: "Old documents", location: "Bedroom")
            ]
        )
    }

    static let defaultModes: [ModePreset] = [
        ModePreset(
            title: "Leaving for 10 Days",
            subtitle: "Secure your home before a trip",
            steps: [
                PlanStep(title: "Secure entryway", detail: "Lock doors and enable entry alerts", minutes: 5),
                PlanStep(title: "Set light schedule", detail: "Turn on evening scenes for presence", minutes: 4),
                PlanStep(title: "Pause risky devices", detail: "Unplug small appliances", minutes: 6)
            ]
        ),
        ModePreset(
            title: "Guests Coming",
            subtitle: "Prepare rooms, supplies and details",
            steps: [
                PlanStep(title: "Reset entryway", detail: "Put away shoes, bags and visible clutter", minutes: 5),
                PlanStep(title: "Refresh bathroom", detail: "Towels, mirror, sink, toilet paper", minutes: 8),
                PlanStep(title: "Clear kitchen surfaces", detail: "Dishes, trash, counter wipe", minutes: 10),
                PlanStep(title: "Prepare guest details", detail: "Wi-Fi, water, charger, towels", minutes: 5)
            ]
        ),
        ModePreset(
            title: "20-Min Reset",
            subtitle: "A fast cleanup plan for messy days",
            steps: [
                PlanStep(title: "Collect visible clutter", detail: "Use one basket for fast sorting", minutes: 6),
                PlanStep(title: "Wipe high-touch spots", detail: "Kitchen and entry surfaces", minutes: 7),
                PlanStep(title: "Reset living room", detail: "Pillows, throw, coffee table", minutes: 7)
            ]
        ),
        ModePreset(
            title: "Deep Clean",
            subtitle: "Room-by-room cleaning system",
            steps: [
                PlanStep(title: "Kitchen cycle", detail: "Counters, sink, appliances", minutes: 20),
                PlanStep(title: "Bathroom cycle", detail: "Toilet, shower, mirror", minutes: 20),
                PlanStep(title: "Floors and dust", detail: "All main rooms", minutes: 20)
            ]
        ),
        ModePreset(
            title: "Move Out",
            subtitle: "Pack, clean and check everything",
            steps: [
                PlanStep(title: "Pack essentials", detail: "Separate this-week items", minutes: 25),
                PlanStep(title: "Label boxes", detail: "Generate QR labels by room", minutes: 20),
                PlanStep(title: "Final checks", detail: "Meters, keys, doors, photos", minutes: 15)
            ]
        )
    ]
}

private extension Color {
    static let backgroundCream = Color(red: 0.75, green: 0.68, blue: 0.59)
    static let backgroundSand = Color(red: 0.61, green: 0.54, blue: 0.48)
    static let softBlue = Color(red: 0.47, green: 0.56, blue: 0.67)
    static let cardWhite = Color(red: 0.98, green: 0.98, blue: 0.99)
    static let inkBlack = Color(red: 0.14, green: 0.15, blue: 0.17)
    static let mutedGray = Color(red: 0.43, green: 0.45, blue: 0.49)
    static let accentGreen = Color(red: 0.21, green: 0.63, blue: 0.43)
    static let accentOrange = Color(red: 0.86, green: 0.52, blue: 0.29)
    static let accentPurple = Color(red: 0.45, green: 0.41, blue: 0.72)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
