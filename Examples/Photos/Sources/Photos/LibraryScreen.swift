//
//  LibraryScreen.swift
//  Photos
//
//  The photo grid — the whole library, the favourites, or an album. A
//  `LazyVGrid` with adaptive columns: as many as fit at the zoom's tile
//  size, re-flowed as the window or the zoom changes. Each month is a
//  `Section` whose header stays pinned at the top while its photos scroll
//  under it. Of twenty thousand tiles, only the few hundred near the
//  visible part are ever built.
//

import NucleantUI

@View
struct PhotoGridScreen {
    let library: Library
    let title: String
    let months: [MonthGroup]

    var body: some View {
        let library = self.library
        let count = months.reduce(0) { $0 + $1.photos.count }
        VStack(spacing: 0) {
            ScreenBar(title: title, subtitle: "\(grouped(count)) Photos") {
                ZoomControl(library: library)
            }
            Divider()
            if months.isEmpty {
                Text("No Photos")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: library.tileSize), spacing: 3)],
                        spacing: 3,
                        pinnedViews: [.sectionHeaders]
                    ) {
                        ForEach(months) { month in
                            Section {
                                ForEach(month.photos) { photo in
                                    PhotoTile(library: library, photo: photo)
                                }
                            } header: {
                                MonthHeader(month: month)
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
    }
}

/// A month's name and count, over a bar that hides the tiles scrolling
/// under it while it is pinned.
@View
struct MonthHeader {
    let month: MonthGroup

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Text(month.title)
                .font(.system(size: 17, weight: .bold))
            Text("\(month.photos.count) photos")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.bar.opacity(0.94))
    }
}

/// The tile size, as a slider between two squares.
@View
struct ZoomControl {
    @Bindable var library: Library

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary)
                .frame(width: 8, height: 8)
            Slider(value: $library.tileSize, in: 60...260)
                .frame(width: 140)
            RoundedRectangle(cornerRadius: 2.5)
                .fill(Color.secondary)
                .frame(width: 14, height: 14)
        }
    }
}

/// The bar over every screen: a title, a line under it, and the screen's
/// own controls at the trailing end.
@View
struct ScreenBar<Controls: View> {
    let title: String
    let subtitle: String
    let controls: Controls

    init(title: String, subtitle: String, _viewID: ViewID = #viewID, @ViewBuilder controls: () -> Controls) {
        self.title = title
        self.subtitle = subtitle
        self.controls = controls()
        self._viewID = _viewID
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.bar)
    }
}
