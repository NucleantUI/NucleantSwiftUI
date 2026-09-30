//
//  Model.swift
//  Photos
//
//  The photo library: twenty thousand photos over six years, grouped into
//  months and days, and the albums made from them. `Library` is the
//  `@Observable` model — favourites, the selection and the zoom change
//  through it; a `Photo` is a record inside it. The photos are generated
//  from a fixed seed, so the library is the same every launch; each one's
//  picture is a `Scenery` — sky, sun and hills — drawn by `PhotoArt`.
//

import Foundation
import NucleantUI
import Observation

// MARK: - Values

/// What a photo shows, drawn rather than decoded.
struct Scenery: Hashable {
    let skyTop: Color
    let skyBottom: Color
    let sun: Color
    /// Where the sun sits, in the picture's unit square.
    let sunPosition: UnitPoint
    let farHills: Color
    let nearHills: Color
    /// Ridge heights, left to right, as fractions of the picture's height.
    let farRidge: [Double]
    let nearRidge: [Double]
}

struct Photo: Identifiable, Hashable {
    let id: Int
    let name: String
    let date: Date
    let scenery: Scenery
    let pixelWidth: Int
    let pixelHeight: Int
    let camera: String
    let lens: String
    let iso: Int
    let aperture: Double
    let shutter: String
    let focalLength: Int
    let bytes: Int
    let place: String

    static func == (a: Photo, b: Photo) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A month of the library, newest photo first.
struct MonthGroup: Identifiable, Equatable {
    /// `year * 100 + month`.
    let id: Int
    let title: String
    let photos: [Photo]

    /// Photos are only ever added or removed, so a month with the same
    /// count holds the same photos — no need to walk them.
    static func == (a: MonthGroup, b: MonthGroup) -> Bool {
        a.id == b.id && a.photos.count == b.photos.count
    }
}

/// One day's photos, and where most of them were taken.
struct DayGroup: Identifiable, Equatable {
    /// `year * 10000 + month * 100 + day`.
    let id: Int
    let weekday: String
    let date: String
    let place: String
    let photos: [Photo]

    static func == (a: DayGroup, b: DayGroup) -> Bool {
        a.id == b.id && a.photos.count == b.photos.count
    }
}

struct Album: Identifiable, Hashable {
    let id: Int
    let name: String
    let isShared: Bool
    let isPinned: Bool
    let photoIDs: [Int]
}

// MARK: - The library

@MainActor
@Observable
final class Library {
    /// Newest first.
    let photos: [Photo]
    let months: [MonthGroup]
    let days: [DayGroup]
    let albums: [Album]

    private(set) var favorites: Set<Photo.ID> = []
    private(set) var selectedID: Photo.ID?
    /// The smallest a tile in the library grid may be; the grid fits as
    /// many columns as it can at this width.
    var tileSize: Double = 110

    private let byID: [Photo.ID: Photo]

    init(count: Int = 20_000) {
        var random = SeededRandom(seed: 0x5EED_0F_F070)
        let photos = Self.makePhotos(count: count, random: &random)
        self.photos = photos
        self.byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        self.months = Self.groupByMonth(photos)
        self.days = Self.groupByDay(photos)
        self.albums = Self.makeAlbums(from: photos, random: &random)
        // A few favourites to start with, spread over the years.
        favorites = Set(photos.indices.filter { $0 % 97 == 13 }.map { photos[$0].id })
    }

    // MARK: Reading

    func photo(_ id: Photo.ID) -> Photo? { byID[id] }

    var selectedPhoto: Photo? { selectedID.flatMap { byID[$0] } }

    func isFavorite(_ id: Photo.ID) -> Bool { favorites.contains(id) }

    /// The favourites, newest first, grouped by month like the library.
    var favoriteMonths: [MonthGroup] {
        Self.groupByMonth(photos.filter { favorites.contains($0.id) })
    }

    func album(_ id: Album.ID) -> Album? { albums.first { $0.id == id } }

    func photos(in album: Album) -> [Photo] {
        album.photoIDs.compactMap { byID[$0] }
    }

    /// An album's photos grouped by month.
    func months(in album: Album) -> [MonthGroup] {
        Self.groupByMonth(photos(in: album).sorted { $0.date > $1.date })
    }

    /// The albums a photo is in.
    func albums(containing id: Photo.ID) -> [Album] {
        albums.filter { $0.photoIDs.contains(id) }
    }

    // MARK: Changing

    func select(_ id: Photo.ID?) {
        selectedID = id
    }

    func toggleFavorite(_ id: Photo.ID) {
        if favorites.contains(id) {
            favorites.remove(id)
        } else {
            favorites.insert(id)
        }
    }

    // MARK: Generating

    private static let cameras = [
        ("Nucleant One", ["24mm f/1.8", "50mm f/1.4", "85mm f/1.8"]),
        ("Fieldmark X2", ["16–35mm f/4", "24–70mm f/2.8"]),
        ("Pocket 7", ["Wide 26mm", "Ultra Wide 13mm", "Tele 77mm"]),
    ]

    private static let places = [
        "Lisbon", "Porto", "Sintra", "Madrid", "Granada", "Reykjavík", "Oslo",
        "Bergen", "Tromsø", "Kyoto", "Osaka", "Nara", "Vancouver", "Whistler",
        "Banff", "Home", "Home", "Home", "The Coast", "The Lake",
    ]

    private static let shutters = ["1/30", "1/60", "1/125", "1/250", "1/500", "1/1000", "1/2000", "1/4000"]

    private static func makePhotos(count: Int, random: inout SeededRandom) -> [Photo] {
        // Back from the end of September 2026, a few photos a day on
        // average, more on some days than others.
        var date = Date(timeIntervalSince1970: 1_790_000_000)
        var place = places[0]
        var photos: [Photo] = []
        photos.reserveCapacity(count)
        for index in 0..<count {
            let gap = random.nextDouble() < 0.12
                ? random.nextDouble(in: 20_000...200_000)
                : random.nextDouble(in: 20...2_400)
            date = date.addingTimeInterval(-gap)
            if gap > 40_000 { place = places[random.nextInt(places.count)] }
            let (camera, lenses) = cameras[random.nextInt(cameras.count)]
            let portrait = random.nextDouble() < 0.25
            photos.append(Photo(
                id: 100_000 + count - index,
                name: String(format: "IMG_%04d", (count - index) % 10_000),
                date: date,
                scenery: makeScenery(at: date, random: &random),
                pixelWidth: portrait ? 3024 : 4032,
                pixelHeight: portrait ? 4032 : 3024,
                camera: camera,
                lens: lenses[random.nextInt(lenses.count)],
                iso: [50, 100, 200, 400, 800, 1600][random.nextInt(6)],
                aperture: [1.4, 1.8, 2.8, 4, 5.6, 8, 11][random.nextInt(7)],
                shutter: shutters[random.nextInt(shutters.count)],
                focalLength: [13, 24, 26, 35, 50, 77, 85][random.nextInt(7)],
                bytes: 1_800_000 + random.nextInt(4_200_000),
                place: place
            ))
        }
        return photos
    }

    /// A landscape whose light follows the hour — blue at noon, orange at
    /// dusk, deep blue at night — and whose hills follow the seed.
    private static func makeScenery(at date: Date, random: inout SeededRandom) -> Scenery {
        let hour = Double(calendar.component(.hour, from: date)) + random.nextDouble()
        let daylight = max(0, sin((hour - 6) / 12 * .pi))
        let warmth = max(0, 1 - abs(hour - 18.5) / 2.5) + max(0, 1 - abs(hour - 6.5) / 2)
        let hue = random.nextDouble(in: 0...0.08)
        let skyTop = hsb(0.60 - hue, 0.55, 0.25 + 0.65 * daylight)
        let skyBottom = hsb(0.58 - 0.5 * warmth * 0.55, 0.30 + 0.45 * warmth, 0.35 + 0.6 * max(daylight, warmth * 0.8))
        let sun = hsb(0.12 - 0.08 * warmth, 0.25 + 0.6 * warmth, 1)
        let green = random.nextDouble(in: 0.22...0.40)
        func ridge(_ low: Double, _ high: Double) -> [Double] {
            (0..<6).map { _ in random.nextDouble(in: low...high) }
        }
        return Scenery(
            skyTop: skyTop,
            skyBottom: skyBottom,
            sun: sun,
            sunPosition: UnitPoint(x: random.nextDouble(in: 0.15...0.85), y: 0.62 - 0.45 * daylight),
            farHills: hsb(green + 0.25, 0.30, 0.22 + 0.40 * daylight),
            nearHills: hsb(green, 0.55, 0.14 + 0.45 * daylight),
            farRidge: ridge(0.45, 0.65),
            nearRidge: ridge(0.62, 0.82)
        )
    }

    private static func makeAlbums(from photos: [Photo], random: inout SeededRandom) -> [Album] {
        var albums: [Album] = []
        // One album per trip: the photos taken away from home in a run.
        var run: [Photo] = []
        func closeRun() {
            if run.count >= 12, let first = run.last, let place = run.first?.place, place != "Home" {
                let year = calendar.component(.year, from: first.date)
                albums.append(Album(
                    id: albums.count + 1,
                    name: "\(place) \(year)",
                    isShared: albums.count % 5 == 3,
                    isPinned: albums.count < 6,
                    photoIDs: run.map(\.id)
                ))
            }
            run.removeAll()
        }
        for photo in photos {
            if let last = run.last, last.place != photo.place { closeRun() }
            run.append(photo)
        }
        closeRun()
        // And a few that pick across the years.
        let themed = [("Sunsets", 0.04), ("Mountains", 0.03), ("Family", 0.05), ("Best of", 0.01)]
        for (name, share) in themed {
            albums.append(Album(
                id: albums.count + 1,
                name: name,
                isShared: name == "Family",
                isPinned: true,
                photoIDs: photos.filter { _ in random.nextDouble() < share }.map(\.id)
            ))
        }
        return albums
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon") ?? .current
        return calendar
    }()

    private static let monthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "LLLL yyyy"
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMMM yyyy 'at' HH:mm"
        return formatter
    }()

    private static func groupByMonth(_ photos: [Photo]) -> [MonthGroup] {
        var groups: [MonthGroup] = []
        var current: [Photo] = []
        var key = 0
        func close() {
            guard let first = current.first else { return }
            groups.append(MonthGroup(id: key, title: monthFormatter.string(from: first.date), photos: current))
            current.removeAll()
        }
        for photo in photos {
            let parts = calendar.dateComponents([.year, .month], from: photo.date)
            let next = (parts.year ?? 0) * 100 + (parts.month ?? 0)
            if next != key { close(); key = next }
            current.append(photo)
        }
        close()
        return groups
    }

    private static func groupByDay(_ photos: [Photo]) -> [DayGroup] {
        var groups: [DayGroup] = []
        var current: [Photo] = []
        var key = 0
        func close() {
            guard let first = current.first else { return }
            // Where most of the day's photos were taken.
            let counts = Dictionary(grouping: current, by: \.place).mapValues(\.count)
            let place = counts.max { $0.value < $1.value }?.key ?? first.place
            groups.append(DayGroup(
                id: key,
                weekday: weekdayFormatter.string(from: first.date),
                date: dayFormatter.string(from: first.date),
                place: place,
                photos: current
            ))
            current.removeAll()
        }
        for photo in photos {
            let parts = calendar.dateComponents([.year, .month, .day], from: photo.date)
            let next = (parts.year ?? 0) * 10_000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
            if next != key { close(); key = next }
            current.append(photo)
        }
        close()
        return groups
    }
}

// MARK: - Helpers

/// A colour from hue, saturation and brightness, each 0…1.
func hsb(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
    let h = (hue - hue.rounded(.down)) * 6
    let s = min(max(saturation, 0), 1)
    let v = min(max(brightness, 0), 1)
    let sector = Int(h) % 6
    let f = h - Double(Int(h))
    let p = v * (1 - s)
    let q = v * (1 - s * f)
    let t = v * (1 - s * (1 - f))
    let (r, g, b): (Double, Double, Double)
    switch sector {
    case 0:  (r, g, b) = (v, t, p)
    case 1:  (r, g, b) = (q, v, p)
    case 2:  (r, g, b) = (p, v, t)
    case 3:  (r, g, b) = (p, q, v)
    case 4:  (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return Color(red: r, green: g, blue: b)
}

/// SplitMix64: the same library from the same seed, every launch.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func nextDouble(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextDouble()
    }

    mutating func nextInt(_ upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}
