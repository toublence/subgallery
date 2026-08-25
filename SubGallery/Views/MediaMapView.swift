import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct MediaMapView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    let templatePurpose: CapturePurpose
    let title: String
    @StateObject private var placeNames = MapPlaceNameStore()
    @State private var section: MapSection = .map
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedClusterID: String?
    @State private var viewerItem: MediaItem?
    @State private var selectedYear: Int?
    @State private var mapPresentation: MapPresentation = .regions
    @AppStorage("camera.saveLocation") private var savesLocation = false

    private var allLocatedItems: [MediaItem] {
        media.filter { item in
            item.deletedAt == nil
                && item.templatePurpose == templatePurpose
                && item.latitude.map { (-90...90).contains($0) } == true
                && item.longitude.map { (-180...180).contains($0) } == true
        }
    }

    private var locatedItems: [MediaItem] {
        guard let selectedYear else { return allLocatedItems }
        return allLocatedItems.filter { Calendar.current.component(.year, from: $0.createdAt) == selectedYear }
    }

    private var availableYears: [Int] {
        Set(allLocatedItems.map { Calendar.current.component(.year, from: $0.createdAt) }).sorted(by: >)
    }

    private var clusters: [MediaMapCluster] {
        MediaMapCluster.make(from: locatedItems)
    }

    private var timeline: [MediaTimelineStop] {
        MediaTimelineStop.make(from: locatedItems)
    }

    private var selectedCluster: MediaMapCluster? {
        clusters.first { $0.id == selectedClusterID }
    }

    private var routeCoordinates: [CLLocationCoordinate2D] {
        timeline.reversed().map(\.coordinate)
    }

    var body: some View {
        ZStack {
            if locatedItems.isEmpty {
                emptyState
            } else if section == .map {
                mapContent
            } else {
                timelineContent
            }
        }
        .background(section == .map ? Color.travelInk : Color(.systemGroupedBackground))
        .safeAreaInset(edge: .top, spacing: 0) { journeyControls }
        .navigationTitle(L10n.format("%@ 지도", title))
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: locatedItems, initialID: item.id, isRecentlyDeleted: false)
        }
        .task(id: timeline.map(\.id)) {
            await placeNames.load(stops: Array(timeline.prefix(30)))
        }
        .task {
            await backfillStoredMetadata()
        }
        .onChange(of: selectedYear) { _, _ in
            selectedClusterID = nil
            position = .automatic
        }
    }

    private var journeyControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [.cyan, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "map.fill")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(mapSummary)
                        .font(.caption)
                        .opacity(0.7)
                }
                Spacer()
                if section == .map, !locatedItems.isEmpty {
                    Button {
                        selectedClusterID = nil
                        position = .automatic
                    } label: {
                        Image(systemName: "scope")
                            .font(.headline)
                            .frame(width: 40, height: 40)
                            .background(.thinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.text("전체 위치 보기"))
                }
            }

            HStack(spacing: 6) {
                ForEach(MapSection.allCases) { value in
                    Button {
                        withAnimation(.snappy) { section = value }
                    } label: {
                        Label(value.title, systemImage: value.symbol)
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(section == value ? Color.white : Color.clear, in: Capsule())
                            .foregroundStyle(section == value ? Color.travelInk : controlsForeground.opacity(0.72))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(controlsForeground.opacity(0.1), in: Capsule())

            if !availableYears.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        yearButton(nil, title: "전체")
                        ForEach(availableYears, id: \.self) { year in
                            yearButton(year, title: L10n.format("%d년", year))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .foregroundStyle(controlsForeground)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background { controlsBackground }
    }

    private var controlsForeground: Color {
        section == .map ? .white : .primary
    }

    @ViewBuilder
    private var controlsBackground: some View {
        if section == .map {
            LinearGradient(colors: [Color.travelInk, Color.travelNavy], startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            Color(.secondarySystemGroupedBackground)
                .overlay(alignment: .bottom) { Divider() }
        }
    }

    private func yearButton(_ year: Int?, title: String) -> some View {
        let isSelected = selectedYear == year
        return Button {
            withAnimation(.snappy) { selectedYear = year }
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(isSelected ? Color.travelCoral : controlsForeground.opacity(0.09), in: Capsule())
                .foregroundStyle(isSelected ? .white : controlsForeground.opacity(0.72))
        }
        .buttonStyle(.plain)
    }

    private var mapSummary: String {
        guard !locatedItems.isEmpty else { return L10n.text("사진의 위치로 타임라인을 자동 생성합니다") }
        return L10n.format("%d곳 · 사진과 동영상 %d개", clusters.count, locatedItems.count)
    }

    private var mapContent: some View {
        Map(position: $position) {
            if mapPresentation == .regions, routeCoordinates.count > 1 {
                MapPolyline(coordinates: routeCoordinates)
                    .stroke(
                        Color.travelCoral.opacity(0.68),
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [4, 8])
                    )
            }
            ForEach(clusters) { cluster in
                MapCircle(
                    center: cluster.coordinate,
                    radius: mapPresentation == .regions ? 18_000 : 5_000
                )
                .foregroundStyle(
                    mapPresentation == .regions
                        ? cluster.tint.opacity(0.3)
                        : Color.white.opacity(0.06)
                )
                Annotation("", coordinate: cluster.coordinate, anchor: .bottom) {
                    Button {
                        withAnimation(.snappy) { selectedClusterID = cluster.id }
                    } label: {
                        if mapPresentation == .regions {
                            MapClusterMarker(cluster: cluster, isSelected: selectedClusterID == cluster.id)
                        } else {
                            FootprintGlowMarker(cluster: cluster, isSelected: selectedClusterID == cluster.id)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("위치 사진 \(cluster.items.count)개")
                }
            }
        }
        .mapStyle(.standard(elevation: .flat))
        .environment(\.colorScheme, mapPresentation == .footprints ? .dark : .light)
        .overlay(alignment: .top) {
            mapModeControls
        }
        .overlay(alignment: .bottom) {
            if let selectedCluster {
                selectedClusterCard(selectedCluster)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                mapOverviewCard
                    .transition(.opacity)
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var mapModeControls: some View {
        HStack(spacing: 8) {
            Label(
                mapPresentation == .regions ? "방문 지역을 색으로 표시" : "사진이 빛나는 나의 발자취",
                systemImage: mapPresentation.symbol
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(mapPresentation == .footprints ? .white : Color.travelInk)

            Spacer()

            HStack(spacing: 3) {
                ForEach(MapPresentation.allCases) { style in
                    Button {
                        withAnimation(.snappy) {
                            mapPresentation = style
                            selectedClusterID = nil
                        }
                    } label: {
                        Image(systemName: style.symbol)
                            .frame(width: 34, height: 30)
                            .background(
                                mapPresentation == style ? Color.travelCoral : Color.clear,
                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                            )
                            .foregroundStyle(mapPresentation == style ? .white : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(style.title)
                }
            }
            .padding(3)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(12)
    }

    private var mapOverviewCard: some View {
        HStack(spacing: 16) {
            Label(L10n.format("%d곳", clusters.count), systemImage: "mappin.and.ellipse")
            Divider().frame(height: 22).overlay(.white.opacity(0.3))
            Label(L10n.format("%d개 기록", locatedItems.count), systemImage: "photo.stack")
            Spacer()
            Text(L10n.text("사진을 눌러보세요"))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.66))
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.travelInk.opacity(0.9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.2), lineWidth: 0.5)
        }
        .padding(14)
    }

    private func selectedClusterCard(_ cluster: MediaMapCluster) -> some View {
        let dayCount = Set(cluster.items.map { Calendar.current.startOfDay(for: $0.createdAt) }).count
        let latestDate = cluster.items.map(\.createdAt).max() ?? .now
        return VStack(alignment: .leading, spacing: 16) {
            Capsule()
                .fill(.secondary.opacity(0.28))
                .frame(width: 42, height: 4)
                .frame(maxWidth: .infinity)

            HStack {
                Image(systemName: "mappin.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.travelCoral)
                VStack(alignment: .leading, spacing: 3) {
                    Text(placeNames.names[cluster.placeKey] ?? L10n.text("이 위치의 기록"))
                        .font(.title3.bold())
                    Text(L10n.format("%@의 여행 기록", title))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    withAnimation(.snappy) { selectedClusterID = nil }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                clusterMetric(value: "\(cluster.items.count)", title: "사진", symbol: "photo")
                clusterMetric(value: "\(dayCount)", title: "방문 일수", symbol: "calendar")
                clusterMetric(
                    value: latestDate.formatted(.dateTime.month().day()),
                    title: "최근 방문",
                    symbol: "clock"
                )
            }

            HStack {
                Text(L10n.text("최근 사진"))
                    .font(.subheadline.bold())
                Spacer()
                Button(L10n.text("타임라인 보기")) {
                    withAnimation(.snappy) {
                        selectedClusterID = nil
                        section = .timeline
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.travelCoral)
            }

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(cluster.items) { item in
                        Button { viewerItem = item } label: {
                            MediaThumbnail(item: item)
                                .frame(width: 88, height: 88)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(.separator.opacity(0.3), lineWidth: 0.5)
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .foregroundStyle(.primary)
        .padding(16)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.travelCoral.opacity(0.1), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 26, y: 12)
        .padding(14)
        .environment(\.colorScheme, .light)
    }

    private func clusterMetric(value: String, title: String, symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(Color.travelCoral)
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var timelineContent: some View {
        ScrollView {
            VStack(spacing: 18) {
                timelineSummaryCard

                LazyVStack(spacing: 0) {
                    ForEach(Array(timeline.enumerated()), id: \.element.id) { index, stop in
                        TimelineStopRow(
                            stop: stop,
                            placeName: placeNames.names[stop.placeKey],
                            isLast: index == timeline.count - 1,
                            onOpen: { viewerItem = $0 }
                        )
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
    }

    private var timelineSummaryCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("자동 여행 타임라인"))
                        .font(.title2.bold())
                    Text(L10n.text("사진의 시간과 이동 거리로 여행을 정리했어요"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.travelCoral)
            }

            HStack(spacing: 0) {
                timelineMetric(value: "\(clusters.count)", title: "방문 장소", symbol: "mappin")
                timelineMetric(value: "\(travelDayCount)", title: "여행 일수", symbol: "calendar")
                timelineMetric(value: "\(locatedItems.count)", title: "사진 기록", symbol: "photo")
            }
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.travelCoral.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: Color.travelInk.opacity(0.08), radius: 18, y: 8)
    }

    private var travelDayCount: Int {
        Set(locatedItems.map { Calendar.current.startOfDay(for: $0.createdAt) }).count
    }

    private func timelineMetric(value: String, title: String, symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.bold())
                .foregroundStyle(Color.travelCoral)
            Text(value)
                .font(.title3.bold().monospacedDigit())
            Text(L10n.text(title))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color.travelCoral.opacity(0.2), .cyan.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "map.fill")
                        .font(.system(size: 54, weight: .bold))
                        .foregroundStyle(LinearGradient(colors: [Color.travelCoral, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .frame(width: 132, height: 132)

                VStack(spacing: 8) {
                    Text(L10n.text("위치가 있는 사진이 없습니다"))
                        .font(.title3.bold())
                    Text(L10n.text("위치 정보가 포함된 사진을 가져오거나, 새로 촬영할 때 위치 저장을 켜면 기억 지도와 타임라인이 자동으로 만들어집니다."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !savesLocation {
                    Button {
                        savesLocation = true
                    } label: {
                        Label(L10n.text("새 촬영에 위치 저장"), systemImage: "location.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.travelCoral)
                }
            }
            .frame(maxWidth: 430)
            .padding(.horizontal, 32)
            .padding(.top, 64)
        }
    }

    @MainActor
    private func backfillStoredMetadata() async {
        var changed = false
        for item in media where item.deletedAt == nil
            && item.templatePurpose == templatePurpose
            && item.kind == .photo
            && (item.latitude == nil || item.longitude == nil) {
            _ = item.mediaURL
            let metadata = await MediaStorage.shared.metadata(for: item.localPath)
            guard let latitude = metadata.latitude, let longitude = metadata.longitude else { continue }
            item.latitude = latitude
            item.longitude = longitude
            if let capturedAt = metadata.capturedAt { item.createdAt = capturedAt }
            changed = true
        }
        if changed { try? modelContext.save() }
    }
}

private enum MapSection: String, CaseIterable, Identifiable {
    case map
    case timeline

    var id: String { rawValue }
    var title: String { L10n.text(self == .map ? "지도" : "타임라인") }
    var symbol: String { self == .map ? "map" : "point.topleft.down.to.point.bottomright.curvepath" }
}

private enum MapPresentation: String, CaseIterable, Identifiable {
    case regions
    case footprints

    var id: String { rawValue }
    var title: String { L10n.text(self == .regions ? "여행 지도" : "빛나는 발자취") }
    var symbol: String { self == .regions ? "map.fill" : "sparkles" }
}

private struct MediaMapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let items: [MediaItem]

    var placeKey: String { id }

    var tint: Color {
        let value = id.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        let colors: [Color] = [
            Color(red: 0.98, green: 0.48, blue: 0.45),
            Color(red: 0.33, green: 0.76, blue: 0.72),
            Color(red: 0.48, green: 0.62, blue: 0.96),
            Color(red: 0.96, green: 0.73, blue: 0.32),
            Color(red: 0.69, green: 0.52, blue: 0.92)
        ]
        return colors[value % colors.count]
    }

    static func make(from items: [MediaItem]) -> [MediaMapCluster] {
        let located = items.compactMap { item -> (MediaItem, CLLocationCoordinate2D)? in
            guard let latitude = item.latitude, let longitude = item.longitude else { return nil }
            return (item, CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        let grouped = Dictionary(grouping: located) { pair in
            let coordinate = pair.1
            return "\(Int((coordinate.latitude / 0.025).rounded())):\(Int((coordinate.longitude / 0.025).rounded()))"
        }
        return grouped.map { key, values in
            let latitude = values.map { $0.1.latitude }.reduce(0, +) / Double(values.count)
            let longitude = values.map { $0.1.longitude }.reduce(0, +) / Double(values.count)
            return MediaMapCluster(
                id: key,
                coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                items: values.map(\.0).sorted { $0.createdAt > $1.createdAt }
            )
        }
    }
}

private struct MediaTimelineStop: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let date: Date
    var items: [MediaItem]

    var placeKey: String {
        "\(Int((coordinate.latitude / 0.025).rounded())):\(Int((coordinate.longitude / 0.025).rounded()))"
    }

    static func make(from items: [MediaItem]) -> [MediaTimelineStop] {
        let sorted = items.sorted { $0.createdAt < $1.createdAt }
        var stops: [MediaTimelineStop] = []

        for item in sorted {
            guard let latitude = item.latitude, let longitude = item.longitude else { continue }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if let last = stops.last,
               Calendar.current.isDate(last.date, inSameDayAs: item.createdAt),
               CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
                .distance(from: CLLocation(latitude: latitude, longitude: longitude)) <= 15_000,
               item.createdAt.timeIntervalSince(last.items.last?.createdAt ?? last.date) <= 8 * 60 * 60 {
                stops[stops.count - 1].items.append(item)
            } else {
                stops.append(MediaTimelineStop(
                    id: "\(item.createdAt.timeIntervalSinceReferenceDate)-\(item.id.uuidString)",
                    coordinate: coordinate,
                    date: item.createdAt,
                    items: [item]
                ))
            }
        }
        return Array(stops.reversed())
    }
}

private struct MapClusterMarker: View {
    let cluster: MediaMapCluster
    let isSelected: Bool

    var body: some View {
        VStack(spacing: -5) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.cyan.opacity(0.34))
                        .frame(width: isSelected ? 72 : 62, height: isSelected ? 72 : 62)
                        .blur(radius: 12)

                    MediaThumbnail(item: cluster.items[0])
                        .frame(width: isSelected ? 66 : 56, height: isSelected ? 66 : 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(.white, lineWidth: isSelected ? 4 : 3)
                        }
                        .shadow(color: .black.opacity(0.46), radius: 9, y: 5)
                }

                if cluster.items.count > 1 {
                    Text("\(cluster.items.count)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.travelCoral, in: Capsule())
                        .overlay(Capsule().stroke(.white, lineWidth: 2))
                        .offset(x: 7, y: -7)
                }
            }
            Image(systemName: "triangle.fill")
                .font(.caption)
                .rotationEffect(.degrees(180))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
        }
        .animation(.snappy, value: isSelected)
    }
}

private struct FootprintGlowMarker: View {
    let cluster: MediaMapCluster
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.cyan.opacity(0.3))
                .frame(width: isSelected ? 66 : 54, height: isSelected ? 66 : 54)
                .blur(radius: 14)

            Circle()
                .fill(.white.opacity(0.55))
                .frame(width: isSelected ? 36 : 29, height: isSelected ? 36 : 29)
                .blur(radius: 7)

            ForEach(0..<min(cluster.items.count + 2, 7), id: \.self) { index in
                Circle()
                    .fill(index.isMultiple(of: 2) ? Color.white : Color.cyan)
                    .frame(width: index == 0 ? 10 : 5, height: index == 0 ? 10 : 5)
                    .offset(glowOffset(for: index))
                    .shadow(color: .white, radius: index == 0 ? 8 : 4)
            }

            if cluster.items.count > 1 {
                Text("\(cluster.items.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(Color.travelInk)
                    .padding(5)
                    .background(.white, in: Circle())
                    .offset(x: 23, y: -21)
            }
        }
        .frame(width: isSelected ? 70 : 58, height: isSelected ? 70 : 58)
        .animation(.snappy, value: isSelected)
    }

    private func glowOffset(for index: Int) -> CGSize {
        let offsets = [
            CGSize.zero,
            CGSize(width: -13, height: -8),
            CGSize(width: 14, height: 7),
            CGSize(width: -9, height: 14),
            CGSize(width: 10, height: -15),
            CGSize(width: 18, height: -5),
            CGSize(width: -17, height: 5)
        ]
        return offsets[index % offsets.count]
    }
}

private struct TimelineStopRow: View {
    let stop: MediaTimelineStop
    let placeName: String?
    let isLast: Bool
    let onOpen: (MediaItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle()
                    .fill(Color.travelCoral)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(color: Color.travelCoral.opacity(0.36), radius: 6)
                if !isLast {
                    Rectangle()
                        .fill(LinearGradient(colors: [Color.travelCoral.opacity(0.65), Color.travelCoral.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 2)
                        .frame(minHeight: 286)
                }
            }
            .padding(.top, 20)

            VStack(alignment: .leading, spacing: 12) {
                Button { onOpen(stop.items[0]) } label: {
                    ZStack(alignment: .bottomLeading) {
                        MediaThumbnail(item: stop.items[0])
                            .frame(maxWidth: .infinity)
                            .frame(height: 210)
                            .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .center, endPoint: .bottom)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("자동 생성"))
                                .font(.caption2.bold())
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color.travelCoral, in: Capsule())
                            Text(placeName ?? L10n.text("장소 확인 중"))
                                .font(.title2.bold())
                            Text(stop.date.formatted(date: .long, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .topTrailing) {
                        Label("\(stop.items.count)", systemImage: "photo.fill")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.48), in: Capsule())
                            .padding(12)
                    }
                }
                .buttonStyle(.plain)
                .shadow(color: Color.travelInk.opacity(0.16), radius: 14, y: 7)

                HStack {
                    Label(L10n.format("이 장소의 기록 %d개", stop.items.count), systemImage: "mappin.circle.fill")
                        .foregroundStyle(Color.travelCoral)
                    Spacer()
                    Text(L10n.text("시간·위치로 자동 분류"))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

                if stop.items.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(stop.items.dropFirst()) { item in
                                Button { onOpen(item) } label: {
                                    MediaThumbnail(item: item)
                                        .frame(width: 64, height: 64)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.bottom, 26)
        }
    }
}

private extension Color {
    static let travelInk = Color(red: 0.035, green: 0.055, blue: 0.09)
    static let travelNavy = Color(red: 0.055, green: 0.12, blue: 0.2)
    static let travelCoral = Color(red: 0.96, green: 0.31, blue: 0.27)
}

@MainActor
private final class MapPlaceNameStore: ObservableObject {
    @Published private(set) var names: [String: String] = [:]
    private var loading = Set<String>()

    func load(stops: [MediaTimelineStop]) async {
        for stop in stops where names[stop.placeKey] == nil && !loading.contains(stop.placeKey) {
            loading.insert(stop.placeKey)
            let geocoder = CLGeocoder()
            let placemark = (try? await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: stop.coordinate.latitude, longitude: stop.coordinate.longitude)
            ))?.first
            let components = [placemark?.locality, placemark?.subLocality]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
            names[stop.placeKey] = components.isEmpty
                ? (placemark?.administrativeArea ?? placemark?.country ?? "이 위치의 기록")
                : components.joined(separator: " ")
            loading.remove(stop.placeKey)
        }
    }
}
