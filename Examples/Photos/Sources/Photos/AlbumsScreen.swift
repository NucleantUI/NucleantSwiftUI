//
//  AlbumsScreen.swift
//  Photos
//
//  Albums: the pinned ones as a strip of large covers along the top — a
//  `LazyHStack` in a sideways scroll view — and every album below, as rows
//  of a `LazyVStack` under "Trips", "Collections" and "Shared" headers
//  that stay pinned while their rows scroll. Opening an album shows its
//  photos in the same grid as the library.
//

import NucleantUI

@View
struct AlbumsScreen {
    let library: Library
    let open: (Album.ID) -> Void

    var body: some View {
        let library = self.library
        let pinned = library.albums.filter(\.isPinned)
        let shared = library.albums.filter(\.isShared)
        let trips = library.albums.filter { !$0.isShared && $0.name.last?.isNumber == true }
        let collections = library.albums.filter { !$0.isShared && $0.name.last?.isNumber != true }
        VStack(spacing: 0) {
            ScreenBar(title: "Albums", subtitle: "\(library.albums.count) albums") {
                EmptyView()
            }
            Divider()
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(pinned) { album in
                        AlbumCard(library: library, album: album)
                            .onTapGesture { open(album.id) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(height: 214)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    AlbumSection(title: "Trips", albums: trips, library: library, open: open)
                    AlbumSection(title: "Collections", albums: collections, library: library, open: open)
                    AlbumSection(title: "Shared", albums: shared, library: library, open: open)
                }
            }
        }
    }
}

/// One group of album rows under its pinned header.
@View
struct AlbumSection {
    let title: String
    let albums: [Album]
    let library: Library
    let open: (Album.ID) -> Void

    var body: some View {
        let library = self.library
        Section {
            ForEach(albums) { album in
                AlbumRow(library: library, album: album)
                    .onTapGesture { open(album.id) }
            }
        } header: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text("\(albums.count)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(Theme.bar)
        }
    }
}

/// A large cover with the album's name and count under it.
@View
struct AlbumCard {
    let library: Library
    let album: Album

    var body: some View {
        let photos = library.photos(in: album)
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                if let cover = photos.first {
                    PhotoArt(scenery: cover.scenery)
                } else {
                    Rectangle().fill(Color.fill)
                }
            }
            .frame(width: 150, height: 150)
            .cornerRadius(8)
            Text(album.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Text("\(photos.count) photos")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .frame(width: 150, alignment: .leading)
    }
}

/// A row: a small cover, the name, the count and when.
@View
struct AlbumRow {
    let library: Library
    let album: Album

    var body: some View {
        let photos = library.photos(in: album)
        HStack(spacing: 12) {
            ZStack {
                if let cover = photos.first {
                    PhotoArt(scenery: cover.scenery)
                } else {
                    Rectangle().fill(Color.fill)
                }
            }
            .frame(width: 44, height: 44)
            .cornerRadius(5)
            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(photos.count) photos" + (album.isShared ? " · Shared" : ""))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("›")
                .font(.system(size: 16))
                .foregroundColor(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.secondaryBackground)
    }
}
