import CoreLocation
import MapKit
import SwiftData
import SwiftUI

struct MediaMapView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \MediaItem.createdAt, order: .reverse) private var media: [MediaItem]
    let albumID: UUID
    let albumName: String
    @StateObject private var placeNames = MapPlaceNameStore()
    @State private var section: MapSection = .map
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedClusterID: String?
    @State private var viewerItem: MediaItem?
    @AppStorage("camera.saveLocation") private var savesLocation = false

    private var locatedItems: [MediaItem] {
        media.filter { item in
            item.deletedAt == nil
                && item.albumID == albumID
                && item.latitude.map { (-90...90).contains($0) } == true
                && item.longitude.map { (-180...180).contains($0) } == true
        }
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

    var body: some View {
        VStack(spacing: 0) {
            mapHeader

            Picker("보기", selection: $section) {
                ForEach(MapSection.allCases) { section in
                    Label(section.title, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)

            if locatedItems.isEmpty {
                emptyState
            } else if section == .map {
                mapContent
            } else {
                timelineContent
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("\(albumName) 지도")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if section == .map, !locatedItems.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedClusterID = nil
                        position = .automatic
                    } label: {
                        Label("전체 위치 보기", systemImage: "scope")
                    }
                }
            }
        }
        .fullScreenCover(item: $viewerItem) { item in
            MediaViewer(items: locatedItems, initialID: item.id, isRecentlyDeleted: false)
        }
        .task(id: timeline.map(\.id)) {
            await placeNames.load(stops: Array(timeline.prefix(30)))
        }
        .task {
            await backfillStoredMetadata()
        }
    }

    private var mapHeader: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(.white.opacity(0.18))
                Image(systemName: "map.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(albumName) 이동 기록")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(mapSummary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
            }
            Spacer()
            Image(systemName: "sparkles")
                .foregroundStyle(.yellow)
        }
        .padding(18)
        .background(
            LinearGradient(
                colors: [Color.indigo, Color.blue, Color.cyan.opacity(0.85)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var mapSummary: String {
        guard !locatedItems.isEmpty else { return "사진의 위치로 타임라인을 자동 생성합니다" }
        return "\(clusters.count)곳 · 사진과 동영상 \(locatedItems.count)개"
    }

    private var mapContent: some View {
        Map(position: $position) {
            ForEach(clusters) { cluster in
                Annotation("", coordinate: cluster.coordinate, anchor: .bottom) {
                    Button {
                        withAnimation(.snappy) { selectedClusterID = cluster.id }
                    } label: {
                        MapClusterMarker(cluster: cluster, isSelected: selectedClusterID == cluster.id)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("위치 사진 \(cluster.items.count)개")
                }
            }
        }
        .mapStyle(.standard(elevation: .realistic))
        .overlay(alignment: .bottom) {
            if let selectedCluster {
                selectedClusterCard(selectedCluster)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func selectedClusterCard(_ cluster: MediaMapCluster) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(placeNames.names[cluster.placeKey] ?? "이 위치의 기록")
                        .font(.headline)
                    Text("사진과 동영상 \(cluster.items.count)개")
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

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(cluster.items) { item in
                        Button { viewerItem = item } label: {
                            MediaThumbnail(item: item)
                                .frame(width: 78, height: 78)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.45), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
        .padding(14)
    }

    private var timelineContent: some View {
        ScrollView {
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
            .padding(.horizontal, 18)
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [.indigo.opacity(0.2), .cyan.opacity(0.2)], startPoint: .top, endPoint: .bottom))
                    Image(systemName: "map.circle.fill")
                        .font(.system(size: 64))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.indigo, .white)
                }
                .frame(width: 132, height: 132)

                VStack(spacing: 8) {
                    Text("위치가 있는 사진이 없습니다")
                        .font(.title3.bold())
                    Text("위치 정보가 포함된 사진을 가져오거나, 새로 촬영할 때 위치 저장을 켜면 기억 지도와 타임라인이 자동으로 만들어집니다.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if !savesLocation {
                    Button {
                        savesLocation = true
                    } label: {
                        Label("새 촬영에 위치 저장", systemImage: "location.fill")
                    }
                    .buttonStyle(.borderedProminent)
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
        for item in media where item.deletedAt == nil && item.albumID == albumID && item.kind == .photo
            && (item.latitude == nil || item.longitude == nil) {
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
    var title: String { self == .map ? "지도" : "타임라인" }
    var symbol: String { self == .map ? "map" : "point.topleft.down.to.point.bottomright.curvepath" }
}

private struct MediaMapCluster: Identifiable {
    let id: String
    let coordinate: CLLocationCoordinate2D
    let items: [MediaItem]

    var placeKey: String { id }

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
        ZStack(alignment: .topTrailing) {
            MediaThumbnail(item: cluster.items[0])
                .frame(width: isSelected ? 66 : 56, height: isSelected ? 66 : 56)
                .clipShape(Circle())
                .overlay {
                    Circle().stroke(
                        LinearGradient(colors: [.white, .cyan, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: isSelected ? 5 : 3
                    )
                }
                .shadow(color: .black.opacity(0.3), radius: 7, y: 4)

            if cluster.items.count > 1 {
                Text("\(cluster.items.count)")
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.indigo, in: Capsule())
                    .offset(x: 5, y: -3)
            }
        }
        .animation(.snappy, value: isSelected)
    }
}

private struct TimelineStopRow: View {
    let stop: MediaTimelineStop
    let placeName: String?
    let isLast: Bool
    let onOpen: (MediaItem) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                Circle()
                    .fill(LinearGradient(colors: [.cyan, .indigo], startPoint: .top, endPoint: .bottom))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(color: .indigo.opacity(0.28), radius: 5)
                if !isLast {
                    Rectangle()
                        .fill(LinearGradient(colors: [.indigo.opacity(0.55), .cyan.opacity(0.12)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 3)
                        .frame(minHeight: 236)
                }
            }
            .padding(.top, 16)

            VStack(alignment: .leading, spacing: 10) {
                Button { onOpen(stop.items[0]) } label: {
                    ZStack(alignment: .bottomLeading) {
                        MediaThumbnail(item: stop.items[0])
                            .frame(maxWidth: .infinity)
                            .frame(height: 176)
                            .clipped()
                        LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(placeName ?? "장소 확인 중")
                                .font(.title3.bold())
                            Text(stop.date.formatted(date: .long, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.82))
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                }
                .buttonStyle(.plain)

                HStack {
                    Label("기록 \(stop.items.count)개", systemImage: "photo.on.rectangle.angled")
                    Spacer()
                    Text(String(format: "%.3f, %.3f", stop.coordinate.latitude, stop.coordinate.longitude))
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if stop.items.count > 1 {
                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(stop.items.dropFirst()) { item in
                                Button { onOpen(item) } label: {
                                    MediaThumbnail(item: item)
                                        .frame(width: 56, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .padding(.bottom, 22)
        }
    }
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
