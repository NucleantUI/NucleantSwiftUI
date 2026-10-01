//
//  MindMapApp.swift
//  MindMap
//
//  A mind-mapping app: a library of maps in the sidebar, the selected map
//  on a canvas you drag around (MapCanvas.swift), and a toolbar for naming
//  the map and the selected topic, adding and removing topics, colouring a
//  branch, folding it, and tidying the whole map up.
//
//  Every topic is placed by `.position`, at a point the model keeps (see
//  Model.swift and MapCanvas.swift).
//
//  Where the keys are is one `@FocusState`: the canvas, the map name, the
//  topic title. Adding a topic — Tab or Return on the canvas, or the
//  buttons — puts the keys in the title field so you can name it straight
//  away; Return there hands them back to the canvas, and Tab adds the next
//  child without leaving it.
//

import NucleantUI

enum Theme {
    static let sidebar = Color.dynamic(light: Color(hex: 0xEEEEF2), dark: Color(hex: 0x16181D))
    static let bar = Color.dynamic(light: Color(hex: 0xF7F7F9), dark: Color(hex: 0x1B1D23))
    static let canvas = Color.dynamic(light: Color(hex: 0xF3F1EC), dark: Color(hex: 0x24252A))
    static let bubble = Color.dynamic(light: Color(hex: 0xFFFFFF), dark: Color(hex: 0x33353C))
    static let selection = Color.dynamic(light: Color(hex: 0x1F2329), dark: Color(hex: 0xFFFFFF))
    static let accent = Color(hex: 0x7A6FF0)
}

/// Where the keys can be.
enum Field: Hashable {
    case canvas
    case mapName
    case topicTitle
}

@View
struct MindMapView {
    @State private var library = Library()
    @FocusState private var focus: Field?
    @Environment(\.colorScheme) private var system

    var body: some View {
        let library = self.library
        HStack(spacing: 0) {
            MapList(library: library)
                .frame(width: 220)
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar)
            Divider()
            if let map = library.current {
                VStack(spacing: 0) {
                    Toolbar(map: map, focus: $focus)
                    Divider()
                    MapCanvas(map: map, focus: $focus)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("No map selected")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.secondaryBackground)
        .tint(Theme.accent)
        .colorScheme(AppearanceModel.shared.appearance.scheme ?? system)
        .onAppear { focus = .canvas }
    }
}

@main
struct MindMapApp: NucleantApp {
    var body: some Scene {
        WindowGroup("MindMap", width: 1320, height: 820) {
            MindMapView()
        }
        .commands { AppearanceCommands() }
    }
}

// MARK: - Toolbar

@View
struct Toolbar {
    @Bindable var map: MindMap
    @FocusState.Binding var focus: Field?

    var body: some View {
        let map = self.map
        let selected = map.selectedTopic
        VStack(alignment: .leading, spacing: 10) {
            // The map, and what is done to all of it.
            HStack(spacing: 10) {
                TextField("Map name", text: $map.name)
                    .font(.system(size: 17, weight: .semibold))
                    .focused($focus, equals: .mapName)
                    .onSubmit { focus = .canvas }
                    .frame(minWidth: 160, maxWidth: 300)
                Spacer()
                Text("\(map.topics.count) topics")
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Button("Tidy Up") {
                    withAnimation(.smooth(duration: 0.6)) { map.tidy() }
                }
                Button("Recenter") {
                    withAnimation(.snappy) { map.setPan(.zero) }
                }
            }
            // The selected topic.
            HStack(spacing: 10) {
                TopicTitleField(map: map, topic: selected, focus: $focus)
                    .frame(minWidth: 160, maxWidth: 320)
                Button("Add Child") {
                    guard let id = map.selection else { return }
                    withAnimation(.snappy) { map.addChild(to: id) }
                    focus = .topicTitle
                }
                .disabled(selected == nil)
                Button("Add Sibling") {
                    guard let id = map.selection else { return }
                    withAnimation(.snappy) { map.addSibling(of: id) }
                    focus = .topicTitle
                }
                .disabled(selected == nil)
                Button(selected?.isCollapsed == true ? "Expand" : "Collapse") {
                    guard let id = map.selection else { return }
                    withAnimation(.snappy) { map.toggleCollapsed(id) }
                }
                .disabled(selected.map { map.children(of: $0.id).isEmpty } ?? true)
                Button("Delete") {
                    guard let id = map.selection else { return }
                    withAnimation(.snappy) { map.delete(id) }
                    focus = .canvas
                }
                .disabled(selected?.parentID == nil)
                Spacer()
                ColorRow(map: map, selected: selected)
            }
        }
        .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
        .background(Theme.bar)
    }
}

/// The selected topic's title — where a new topic is named.
@View
struct TopicTitleField {
    let map: MindMap
    let topic: Topic?
    @FocusState.Binding var focus: Field?

    var body: some View {
        let map = self.map
        let id = topic?.id
        TextField(topic == nil ? "Select a topic" : "Topic", text: Binding(
            get: { id.flatMap { map.topic($0)?.title } ?? "" },
            set: { title in
                guard let id else { return }
                map.rename(id, title)
            }
        ))
        .disabled(topic == nil)
        .focused($focus, equals: .topicTitle)
        .onSubmit { focus = .canvas }
        // Tab names this one and starts the next, as on the canvas.
        .onKeyPress(.tab) {
            guard let id else { return .ignored }
            withAnimation(.snappy) { map.addChild(to: id) }
            return .handled
        }
    }
}

/// The palette: a click recolours the selected topic and its branch.
@View
struct ColorRow {
    let map: MindMap
    let selected: Topic?

    var body: some View {
        let map = self.map
        HStack(spacing: 6) {
            ForEach(Palette.colors.indices, id: \.self) { index in
                ColorSwatch(
                    color: Palette.colors[index],
                    isCurrent: selected?.colorIndex == index
                ) {
                    guard let id = map.selection else { return }
                    map.setColor(id, index)
                }
            }
        }
        .opacity(selected == nil ? 0.4 : 1)
        .allowsHitTesting(selected != nil)
    }
}

@View
struct ColorSwatch {
    let color: Color
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        ZStack {
            Circle().fill(color)
            Circle().stroke(isCurrent ? Theme.selection : Color.white, lineWidth: isCurrent ? 2.5 : 1.5)
        }
        .frame(width: 22, height: 22)
        .contentShape(Circle())
        .onTapGesture { action() }
    }
}

// MARK: - Sidebar

@View
struct MapList {
    let library: Library

    var body: some View {
        let library = self.library
        VStack(spacing: 0) {
            List(selection: Binding(get: { library.currentID }, set: { library.currentID = $0 })) {
                Section("Maps") {
                    ForEach(library.maps) { map in
                        MapRow(map: map)
                            .tag(map.id)
                            .badge(map.topics.count)
                            .contextMenu {
                                Button("Delete Map") { library.delete(map.id) }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                Button("New Map") { library.addMap() }
                Spacer()
            }
            .padding(12)
        }
    }
}

@View
struct MapRow {
    let map: MindMap

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Palette.color(map.root.colorIndex))
                .frame(width: 10, height: 10)
            Text(map.name)
                .lineLimit(1)
        }
    }
}
