import SwiftUI

/// The Lists tab: your lists (the whole house's and your own), a new one with a name and who it's for, and in a list:
/// tick off, add, swipe to remove, tap to change. Everything also by voice ("zet melk op de boodschappenlijst").
struct ListsPanel: View {
    @ObservedObject private var lists = Lists.shared
    @ObservedObject private var settings = Settings.shared
    @State private var making = false
    @State private var linking = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(settings.say("Lists", "Lijsten")).font(.largeTitle.bold())
                            if let problem = lists.problem { Text("⚠️ " + problem).font(.caption).foregroundStyle(.orange) }
                        }
                        Spacer()
                        Button { linking = true } label: {
                            Image(systemName: lists.houseCode.isEmpty ? "house" : "house.fill").font(.title3).foregroundStyle(.white.opacity(0.8))
                                .padding(10).background(.ultraThinMaterial, in: Circle())
                        }
                        Button { making = true } label: {
                            Image(systemName: "plus").font(.title3.bold()).foregroundStyle(.white)
                                .padding(10).background(Color.davePurple.opacity(0.8), in: Circle())
                        }
                    }
                    .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 4)
                    List {
                        if lists.visible.isEmpty {
                            Section {
                                listRow { Text(settings.say("No lists yet. Tap + to make one, or say \"make a shopping list\".",
                                                            "Nog geen lijsten. Tik op + om er een te maken, of zeg \"maak een boodschappenlijst\".")).foregroundStyle(.secondary) }
                            }
                        }
                        section(settings.say("The whole house", "Hele huis"), "house")
                        section(settings.say("Just me", "Alleen ik"), "me")
                        if lists.houseCode.isEmpty {
                            Section {
                                listRow {
                                    Button { linking = true } label: {
                                        Label(settings.say("Share lists with the house: link Dave on the Pi", "Lijsten delen met het huis: koppel Dave op de Pi"),
                                              systemImage: "house.and.flag")
                                    }
                                }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .listStyle(.insetGrouped)
                    .refreshable { await lists.listenOnce() }
                }
            }
            .navigationDestination(for: String.self) { id in ListView(id: id) }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $making) { NewListSheet() }
        .sheet(isPresented: $linking) { LinkSheet() }
    }

    @ViewBuilder
    private func section(_ title: String, _ space: String) -> some View {
        let these = lists.visible.filter { $0.space == space }
        if !these.isEmpty {
            Section(title) {
                ForEach(these) { l in
                    listRow {
                        NavigationLink(value: l.id) {
                            HStack {
                                Image(systemName: space == "house" ? "house.fill" : "person.fill").foregroundStyle(Color.daveCyan).frame(width: 24)
                                Text(l.name)
                                Spacer()
                                Text(l.open.isEmpty ? (l.done.isEmpty ? "" : "✓") : "\(l.open.count)").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete { offsets in for i in offsets { lists.delete(these[i].id) } }
            }
        }
    }
}

func listRow<V: View>(@ViewBuilder _ content: () -> V) -> some View {
    content().listRowBackground(Color.white.opacity(0.07))
}

/// One list: what's still to do, what's ticked off, and a field to add more.
struct ListView: View {
    let id: String
    @ObservedObject private var lists = Lists.shared
    @ObservedObject private var settings = Settings.shared
    @State private var newItem = ""
    @State private var editing: Lists.Item?
    @State private var editedText = ""
    @State private var renaming = false
    @State private var newName = ""
    @FocusState private var typing: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            AuroraBackground()
            if let l = lists.list(id) {
                List {
                    Section {
                        listRow {
                            HStack {
                                TextField(settings.say("Add something…", "Iets toevoegen…"), text: $newItem)
                                    .focused($typing).submitLabel(.done).onSubmit(add)
                                Button(action: add) { Image(systemName: "plus.circle.fill").font(.title2) }
                                    .disabled(newItem.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        }
                    } footer: {
                        Text(l.space == "house" ? settings.say("Shared with the whole house (and Dave on the Pi).", "Gedeeld met het hele huis (en Dave op de Pi).")
                                                : settings.say("Just you: only on your own devices.", "Alleen jij: alleen op je eigen apparaten."))
                    }
                    if !l.open.isEmpty {
                        Section { ForEach(l.open) { item in itemRow(item, in: l) }.onDelete { remove($0, from: l.open) } }
                    }
                    if !l.done.isEmpty {
                        Section {
                            ForEach(l.done) { item in itemRow(item, in: l) }.onDelete { remove($0, from: l.done) }
                        } header: {
                            HStack {
                                Text(settings.say("Ticked off", "Afgevinkt"))
                                Spacer()
                                Button(settings.say("Clear", "Wissen")) { lists.clearDone(id) }.font(.caption.bold())
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.insetGrouped)
                .navigationTitle(l.name)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Button { newName = l.name; renaming = true } label: { Label(settings.say("Rename", "Naam veranderen"), systemImage: "pencil") }
                            Button(role: .destructive) { lists.delete(id); dismiss() } label: { Label(settings.say("Delete list", "Lijst verwijderen"), systemImage: "trash") }
                        } label: { Image(systemName: "ellipsis.circle") }
                    }
                }
            } else {
                Text(settings.say("This list is gone.", "Deze lijst is weg.")).foregroundStyle(.secondary)
            }
        }
        .toolbar(.visible, for: .navigationBar)
        .alert(settings.say("Change", "Veranderen"), isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            TextField("", text: $editedText)
            Button(settings.say("Save", "Opslaan")) { if let item = editing { lists.edit(item.id, in: id, to: editedText) }; editing = nil }
            Button(settings.say("Cancel", "Annuleren"), role: .cancel) { editing = nil }
        }
        .alert(settings.say("List name", "Naam van de lijst"), isPresented: $renaming) {
            TextField("", text: $newName)
            Button(settings.say("Save", "Opslaan")) { lists.rename(id, to: newName) }
            Button(settings.say("Cancel", "Annuleren"), role: .cancel) {}
        }
    }

    private func itemRow(_ item: Lists.Item, in l: Lists.List) -> some View {
        listRow {
            HStack(spacing: 12) {
                Button { withAnimation { lists.toggle(item.id, in: id) } } label: {
                    Image(systemName: item.d ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(item.d ? Color.daveCyan : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                Text(item.t).strikethrough(item.d).foregroundStyle(item.d ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { editing = item; editedText = item.t }
            }
        }
    }

    private func add() {
        let text = newItem.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        newItem = ""
        withAnimation { lists.add([text], to: id) }
        typing = true // (keep typing the next one)
    }

    private func remove(_ offsets: IndexSet, from items: [Lists.Item]) {
        lists.remove(offsets.map { items[$0].id }, from: id)
    }
}

/// A new list: its name, and for the whole house or just you.
struct NewListSheet: View {
    @ObservedObject private var lists = Lists.shared
    @ObservedObject private var settings = Settings.shared
    @State private var name = ""
    @State private var space = "me"
    @State private var linking = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(settings.say("Name (e.g. Shopping)", "Naam (bv. Boodschappen)"), text: $name).focused($focused)
                }
                Section {
                    Picker("", selection: $space) {
                        Label(settings.say("The whole house", "Hele huis"), systemImage: "house.fill").tag("house")
                        Label(settings.say("Just me", "Alleen ik"), systemImage: "person.fill").tag("me")
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(lists.houseCode.isEmpty)
                } header: {
                    Text(settings.say("Who it's for", "Voor wie"))
                } footer: {
                    if lists.houseCode.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(settings.say("For the whole house, first link Dave on the Pi.", "Voor het hele huis koppel je eerst Dave op de Pi."))
                            Button(settings.say("Link the house", "Huis koppelen")) { linking = true }
                        }
                    } else {
                        Text(space == "house"
                             ? settings.say("Everyone with the house code sees it and can change it, and Dave on the Pi too.",
                                            "Iedereen met de huiscode ziet en verandert hem, en Dave op de Pi ook.")
                             : settings.say("Only on your own devices.", "Alleen op je eigen apparaten."))
                    }
                }
            }
            .navigationTitle(settings.say("New list", "Nieuwe lijst"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(settings.say("Cancel", "Annuleren")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(settings.say("Make", "Maken")) { lists.create(name, space: space); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true; if !lists.houseCode.isEmpty { space = "house" } }
            .sheet(isPresented: $linking, onDismiss: { if !lists.houseCode.isEmpty { space = "house" } }) { LinkSheet() }
        }
    }
}

/// Linking: the house code (from `sudo dave lijst koppel` on the Pi), and your own code for your other devices.
struct LinkSheet: View {
    @ObservedObject private var lists = Lists.shared
    @ObservedObject private var settings = Settings.shared
    @State private var house = ""
    @State private var mine = ""
    @State private var problem: String?
    @State private var leaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if lists.houseCode.isEmpty {
                        TextField("HUIS-XXXX-XXXX-XXXX-XXXX", text: $house).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button(settings.say("Link", "Koppelen")) {
                            problem = lists.joinHouse(house)
                            if problem == nil { dismiss() }
                        }
                        .disabled(house.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Label(settings.say("Linked with the house", "Gekoppeld met het huis"), systemImage: "checkmark.seal.fill").foregroundStyle(Color.daveCyan)
                        Button(settings.say("Unlink", "Ontkoppelen"), role: .destructive) { leaving = true }
                    }
                } header: {
                    Text(settings.say("The house", "Het huis"))
                } footer: {
                    Text(settings.say("On the Pi: sudo dave lijst koppel. Type the code here, or scan its QR code with the iPhone's camera.",
                                      "Op de Pi: sudo dave lijst koppel. Typ de code hier, of scan de QR-code met de camera van je iPhone."))
                }
                Section {
                    HStack {
                        Text(lists.myCode).font(.body.monospaced())
                        Spacer()
                        Button { UIPasteboard.general.string = lists.myCode } label: { Image(systemName: "doc.on.doc") }
                    }
                    TextField(settings.say("Code from your other device", "Code van je andere apparaat"), text: $mine)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(settings.say("Use this code", "Deze code gebruiken")) {
                        problem = lists.useMyCode(mine)
                        if problem == nil { mine = "" }
                    }
                    .disabled(mine.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text(settings.say("Your own code (lists just for you)", "Je eigen code (lijsten alleen voor jou)"))
                } footer: {
                    Text(settings.say("Your lists just for you are on every device with this code. Keep it to yourself.",
                                      "Je lijsten voor jezelf staan op elk apparaat met deze code. Houd hem voor jezelf."))
                }
                if let problem { Section { Text("⚠️ " + problem).foregroundStyle(.orange) } }
            }
            .navigationTitle(settings.say("Linking", "Koppelen"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(settings.say("Done", "Klaar")) { dismiss() } } }
            .confirmationDialog(settings.say("Unlink the house? Its lists leave this phone.", "Huis ontkoppelen? De lijsten van het huis gaan van deze telefoon af."),
                                isPresented: $leaving, titleVisibility: .visible) {
                Button(settings.say("Unlink", "Ontkoppelen"), role: .destructive) { lists.leaveHouse() }
            }
        }
    }
}
