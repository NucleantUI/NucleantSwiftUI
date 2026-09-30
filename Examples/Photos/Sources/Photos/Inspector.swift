//
//  Inspector.swift
//  Photos
//
//  The info pane for the selected photo: the picture, then its details in
//  a `Grid`. Labels are one column, right-aligned by `gridColumnAlignment`
//  on the first of them; the three exposure values are cells of their own,
//  and a single value takes all three columns with `gridCellColumns`.
//  The rules between groups are `Divider`s marked `gridCellUnsizedAxes`,
//  so they span the grid without widening it, and the Favorite toggle sits
//  after an empty `Color.clear` cell that sizes nothing.
//

import NucleantUI

@View
struct Inspector {
    let library: Library
    let photo: Photo

    var body: some View {
        let library = self.library
        let id = photo.id
        let isFavorite = Binding(
            get: { library.isFavorite(id) },
            set: { _ in library.toggleFavorite(id) }
        )
        let albums = library.albums(containing: id).map(\.name)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Info")
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("✕")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(4)
                    .onTapGesture { library.select(nil) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()

            PhotoArt(scenery: photo.scenery)
                .aspectRatio(Double(photo.pixelWidth) / Double(photo.pixelHeight), contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 260)
                .cornerRadius(6)
                .padding(16)

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    DetailLabel("Name")
                        .gridColumnAlignment(.trailing)
                    Text(photo.name)
                        .font(.system(size: 13, weight: .semibold))
                        .gridCellColumns(3)
                }
                GridRow {
                    DetailLabel("Taken")
                    Text(Library.timeFormatter.string(from: photo.date))
                        .gridCellColumns(3)
                }
                GridRow {
                    DetailLabel("Place")
                    Text(photo.place)
                        .gridCellColumns(3)
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    DetailLabel("Camera")
                    Text(photo.camera)
                        .gridCellColumns(3)
                }
                GridRow {
                    DetailLabel("Lens")
                    Text(photo.lens)
                        .gridCellColumns(3)
                }
                GridRow {
                    DetailLabel("Exposure")
                    ExposureValue("ISO \(photo.iso)")
                    ExposureValue("ƒ/" + trimmed(photo.aperture))
                    ExposureValue("\(photo.shutter) s")
                }
                GridRow {
                    DetailLabel("Image")
                    ExposureValue("\(photo.focalLength) mm")
                    ExposureValue("\(photo.pixelWidth) × \(photo.pixelHeight)")
                        .gridCellColumns(2)
                }
                GridRow {
                    DetailLabel("File")
                    Text(megabytes(photo.bytes) + " HEIC")
                        .gridCellColumns(3)
                }
                Divider()
                    .gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Color.clear
                        .gridCellUnsizedAxes([.horizontal, .vertical])
                    Toggle("Favorite", isOn: isFavorite)
                        .gridCellColumns(3)
                }
                GridRow(alignment: .top) {
                    DetailLabel("Albums")
                    Text(albums.isEmpty ? "None" : albums.joined(separator: ", "))
                        .foregroundColor(albums.isEmpty ? .secondary : .primary)
                        .gridCellColumns(3)
                }
            }
            .padding(.horizontal, 16)

            Spacer()
        }
    }

    private func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private func megabytes(_ bytes: Int) -> String {
        let tenths = (bytes + 50_000) / 100_000
        return "\(tenths / 10).\(tenths % 10) MB"
    }
}

/// A detail's name, in the label column.
@View
struct DetailLabel {
    let text: String

    init(_ text: String, _viewID: ViewID = #viewID) {
        self.text = text
        self._viewID = _viewID
    }

    var body: some View {
        Text(text)
            .foregroundColor(.secondary)
    }
}

/// One exposure value, in a small rounded well.
@View
struct ExposureValue {
    let text: String

    init(_ text: String, _viewID: ViewID = #viewID) {
        self.text = text
        self._viewID = _viewID
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.fill)
            .cornerRadius(4)
    }
}
