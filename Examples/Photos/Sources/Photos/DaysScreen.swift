//
//  DaysScreen.swift
//  Photos
//
//  Days: the library as a timeline running sideways, newest on the left.
//  A `LazyHGrid` with three flexible rows fills each column top to bottom;
//  every day is a `Section` whose header — the weekday, the date, where it
//  was — takes a column of its own and stays pinned at the leading edge
//  while that day's photos scroll past it.
//

import NucleantUI

@View
struct DaysScreen {
    let library: Library

    var body: some View {
        let library = self.library
        VStack(spacing: 0) {
            ScreenBar(title: "Days", subtitle: "\(grouped(library.days.count)) days with photos") {
                EmptyView()
            }
            Divider()
            ScrollView(.horizontal) {
                LazyHGrid(
                    rows: Array(repeating: GridItem(.flexible(minimum: 60), spacing: 4), count: 3),
                    spacing: 4,
                    pinnedViews: [.sectionHeaders]
                ) {
                    ForEach(library.days) { day in
                        Section {
                            ForEach(day.photos) { photo in
                                PhotoTile(library: library, photo: photo, cornerRadius: 4)
                            }
                        } header: {
                            DayHeader(day: day)
                        }
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }
}

/// A day's label, a column tall, opaque so the tiles scrolling under it
/// while it is pinned don't show through.
@View
struct DayHeader {
    let day: DayGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.weekday)
                .font(.system(size: 15, weight: .bold))
            Text(day.date)
                .font(.system(size: 12))
            Text(day.place)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(day.photos.count) photos")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 128, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bar.opacity(0.96))
    }
}
