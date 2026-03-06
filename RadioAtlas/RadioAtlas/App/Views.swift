import SwiftUI
import Foundation
import Combine
import MapKit
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers

/// Filter scope for list views (all items vs favorites).
enum ListScope: String, CaseIterable, Identifiable {
    case all = "All"
    case favorites = "Favorites"
    var id: String { rawValue }
}

/// Tabs available at the root level. The app now launches on Map by default
/// so the splash renders over the map instead of the list-based Places tab.
enum RootTab: Hashable {
    case places
    case map
    case recent
}

/// Top-level container that holds app state and presents the main tabs (Places, Map, Recent).
struct RootView: View {
    // Merge bundled places with any user-added pins created from Map search.
    @State private var places: [Place] = {
        let deleted = DeletedPinsStore.get()
        return (PlaceStore.load() + UserPlaceStore.load())
            .filter { !deleted.contains("place_" + $0.id) }
    }()
    @State private var stations: [RadioStation] = {
        let deleted = DeletedPinsStore.get()
        return RadioStationStore.load()
            .filter { !deleted.contains("station_" + $0.id) }
    }()
    @State private var favorites: Set<String> = FavoritesStore.get()
    @ObservedObject private var audio = AudioManager.shared

    // Persist the user's preferred map style across app launches.
    // Default is `true` to preserve the current satellite appearance.
    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = true


    @StateObject private var recents = RecentManager()
    @StateObject private var photoStore = PinPhotoStore.shared
    @StateObject private var mediaStore = PinMediaStore.shared
    @StateObject private var pinAudioStore = PinAudioSelectionStore.shared

    // Settings.bundle preference: show onboarding on launch.
    @AppStorage(SettingsKeys.showOnboarding) private var showOnboarding: Bool = true

    @State private var selectedTab: RootTab = .map
    @State private var showLaunchSplash: Bool = false
    @State private var showSplash: Bool = false
    @State private var showHelp: Bool = false
    @State private var showRatePrompt: Bool = false
    @State private var pendingRatePrompt: Bool = false
    @State private var playbackErrorMessage: String? = nil
    @State private var didRunLaunchTasks: Bool = false

    private var playbackAlertIsPresented: Binding<Bool> {
        Binding(
            get: { playbackErrorMessage != nil },
            set: { newValue in
                if !newValue { playbackErrorMessage = nil }
            }
        )
    }

    private var helpButton: some View {
        Button {
            AppLog.action("Help opened")
            showHelp = true
        } label: {
            Image(systemName: "questionmark.circle")
        }
        .accessibilityLabel("Help")
    }

    /// Dismisses the launch splash overlay and advances into onboarding when enabled.
    private func dismissLaunchSplash() {
        guard showLaunchSplash else { return }

        AppLog.info("Launch splash overlay dismissed")

        withAnimation(.easeOut(duration: 0.2)) {
            showLaunchSplash = false
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 240_000_000)

            if showOnboarding {
                AppLog.action("Onboarding shown after splash")
                withAnimation(.easeIn(duration: 0.2)) {
                    showSplash = true
                }
            } else if pendingRatePrompt {
                pendingRatePrompt = false
                showRatePrompt = true
            }
        }
    }

    /// Dismisses the onboarding overlay.
    private func dismissSplash() {
        AppLog.action("Onboarding overlay dismissed")

        withAnimation(.easeOut(duration: 0.2)) {
            showSplash = false
        }

        // If the rate prompt is due, present it only after the onboarding is dismissed.
        if pendingRatePrompt {
            pendingRatePrompt = false
            Task { @MainActor in
                // Give the dismissal animation a moment to complete.
                try? await Task.sleep(nanoseconds: 250_000_000)
                showRatePrompt = true
            }
        }
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    PlacesHomeView(places: $places, stations: $stations, favorites: $favorites)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { helpButton }
                }
                .tabItem {
                    Label("Places", systemImage: "list.bullet")
                }
                .tag(RootTab.places)

                NavigationStack {
                    PlacesMapTabView(places: $places, stations: $stations, favorites: $favorites)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { helpButton }
                }
                .tabItem {
                    Label("Map", systemImage: "map")
                }
                .tag(RootTab.map)

                RecentTabView(places: $places, stations: $stations, favorites: $favorites, onHelp: {
                    AppLog.action("Help opened")
                    showHelp = true
                })
                .tabItem {
                    Label("Favorites", systemImage: "star")
                }
                .tag(RootTab.recent)
            }
            .environmentObject(recents)
            .environmentObject(photoStore)
            .environmentObject(mediaStore)
            .environmentObject(pinAudioStore)
            .onChange(of: favorites) { _, newValue in
                FavoritesStore.set(newValue)
            }
            .onChange(of: places) { _, newValue in
                // Persist only user-created pins.
                UserPlaceStore.save(UserPlaceStore.userPlaces(from: newValue))
            }
            .onChange(of: selectedTab) { _, newValue in
                AppLog.info("RootView.selectedTab changed to \(String(describing: newValue))")
            }
            // A persistent bottom play bar showing what is currently playing.
            // NOTE: In a TabView, the system Tab Bar sits at the bottom and can overlap
            // custom overlays/insets. We lift the mini player up a bit so it sits above
            // the Tab Bar instead of stacking on top of it.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Show for both bundled tracks (places) and streaming radio stations.
                if audio.currentTrackBaseName != nil || audio.currentStreamURLString != nil {
                    MiniPlayerBar(favorites: $favorites)
                        // Lift above the TabView's tab bar (avoids overlap with the tab labels).
                        .padding(.bottom, 78)
                }
            }

            if showSplash {
                SplashOnboardingView(onDismiss: dismissSplash)
                    .transition(.opacity)
                    .zIndex(1)
            }

            if showLaunchSplash {
                LaunchSplashOverlayView(onContinue: dismissLaunchSplash)
                    .transition(.opacity)
                    .zIndex(2)
            }
        }
        .sheet(isPresented: $showHelp) {
            InstructionsView()
        }
        // Connectivity / UX: show an alert if playback can't start (e.g., no network).
        .alert("Playback Issue", isPresented: playbackAlertIsPresented) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(playbackErrorMessage ?? "Something went wrong.")
        }
        // Required: custom "Rate this App" alert on 3rd launch.
        .alert("Rate this App in the App Store", isPresented: $showRatePrompt) {
            Button("Rate Now") {
                SettingsManager.markRatePromptShown(userAction: "Rate Now")
            }
            Button("Later", role: .cancel) {
                SettingsManager.markRatePromptShown(userAction: "Later")
            }
        } message: {
            Text("If you enjoy using RadioAtlas, would you mind rating it in the App Store?")
        }
        .onReceive(audio.$userFacingErrorMessage) { msg in
            guard let msg else { return }
            playbackErrorMessage = msg
            audio.clearUserFacingError()
        }
                .task {
            guard !didRunLaunchTasks else { return }
            didRunLaunchTasks = true

            AppLog.action("Launch splash scheduled for launch")
            showLaunchSplash = true

            if SettingsManager.consumePendingRatePrompt() {
                // Avoid presenting the rate prompt on top of the splash or onboarding overlays.
                if showLaunchSplash || showSplash {
                    pendingRatePrompt = true
                } else {
                    showRatePrompt = true
                }
            }
        }
    }
}


// MARK: - Places Home (Countries + Genres dashboard)

/// Summary information for browsing stations by country.
struct CountrySummary: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
    let flagEmoji: String
}

/// Summary information for browsing stations by genre tag.
struct GenreSummary: Identifiable, Hashable {
    let id: String
    let name: String
    let count: Int
}

/// Display-friendly genre label.
/// Some stations ship tags that begin with "And ..." which reads awkwardly in a list.
/// We keep the raw string for filtering/matching, but clean it up for UI display.
fileprivate func displayGenreName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("and ") {
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

/// Card-like header row with an optional "see all" navigation affordance.
private struct SectionHeaderLink<Destination: View>: View {
    let title: String
    let destination: Destination

    init(_ title: String, destination: Destination) {
        self.title = title
        self.destination = destination
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Spacer()
            NavigationLink {
                destination
            } label: {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("See all \(title)")
        }
    }
}

/// Home-style Places tab: nearby stations + quick entry points for countries and genres.
struct PlacesHomeView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @StateObject private var locationManager = LocationManager()

    @State private var activeSheet: ActiveSheet? = nil
    @State private var placeDetent: PresentationDetent = .height(360)
    @State private var stationDetent: PresentationDetent = .height(340)

    @State private var countriesExpanded: Bool = false
    @State private var genresExpanded: Bool = false

    /// Computes the favorites identifier used for a station.
    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    // ActiveSheet defines custom cases and helpers used by this feature area.
    enum ActiveSheet: Identifiable {
        case place(Place)
        case station(RadioStation)

        var id: String {
            switch self {
            case .place(let p): return "place_" + p.id
            case .station(let s): return "station_" + s.id
            }
        }
    }

    
    /// Normalizes a country display name so it can be matched reliably against Apple's localized ISO region names.
    /// This avoids cases like "Antigua And Barbuda" vs. Apple's "Antigua & Barbuda", and trims prefixes like "The ".
    private static func normalizedCountryKey(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: "&", with: "and")
        s = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        s = s.lowercased()

        if s.hasPrefix("the ") {
            s = String(s.dropFirst(4))
        }

        // Keep letters/numbers/spaces only.
        s = s.replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

/// Country name (localized) -> ISO region code mapping cache.
    private static let countryNameToRegionCode: [String: String] = {
        var map: [String: String] = [:]
        let locale = Locale(identifier: "en_US_POSIX")
        // Locale.isoRegionCodes was deprecated in iOS 16.
        // Use Locale.Region.isoRegions (Locale.Region) to enumerate the ISO-3166 region set.
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            if let name = locale.localizedString(forRegionCode: code) {
                map[Self.normalizedCountryKey(name)] = code
            }
        }
        return map
    }()

    /// Converts an ISO region code to a flag emoji (e.g. "US" -> 🇺🇸).
    private func flagEmoji(from regionCode: String) -> String {
        let base: UInt32 = 127397
        var scalars: [UnicodeScalar] = []
        for v in regionCode.uppercased().unicodeScalars {
            guard let scalar = UnicodeScalar(base + v.value) else { continue }
            scalars.append(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func flagEmoji(for countryName: String) -> String {
        let key = Self.normalizedCountryKey(countryName)

        // Manual overrides for cases where Apple's localized region names don't round-trip cleanly.
        // (This is especially common for "China" where iOS may report "China mainland".)
        let overrides: [String: String] = [
            "china": "CN",
            "china mainland": "CN",
            "mainland china": "CN",
            "people's republic of china": "CN",
            "prc": "CN",
            "uae": "AE",
            "united arab emirates": "AE",
            "antigua and barbuda": "AG",
            "bosnia and herzegovina": "BA"
        ]

        if let override = overrides[key] {
            return flagEmoji(from: override)
        }

        guard let code = Self.countryNameToRegionCode[key] else { return "🏳️" }
        return flagEmoji(from: code)
    }

    private var nearbyStations: [RadioStation] {
        // Prefer nearest-first if we have a user coordinate. Fall back to alphabetical.
        guard let coord = locationManager.coordinate else {
            return stations.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }.prefix(10).map { $0 }
        }
        let sorted = stations.sorted { (lhs, rhs) in
            let dl = lhs.distance(from: coord) ?? Double.greatestFiniteMagnitude
            let dr = rhs.distance(from: coord) ?? Double.greatestFiniteMagnitude
            if dl != dr { return dl < dr }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Array(sorted.prefix(10))
    }

    private var countrySummaries: [CountrySummary] {
        let grouped = Dictionary(grouping: stations.filter { !$0.country.isEmpty }, by: { $0.country })
        return grouped
            .map { (key: $0.key, count: $0.value.count) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.key.localizedCaseInsensitiveCompare(rhs.key) == .orderedAscending
            }
            .map { CountrySummary(id: $0.key, name: $0.key, count: $0.count, flagEmoji: flagEmoji(for: $0.key)) }
    }

    private func genreIcon(for genre: String) -> String {
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Common genre shortcuts
        if g.contains("pop") { return "🍿" }
        if g.contains("rock") { return "🎸" }
        if g.contains("elect") || g.contains("edm") { return "🎛️" }
        if g.contains("jazz") { return "🎷" }
        if g.contains("class") { return "🎻" }
        if g.contains("hip") || g.contains("rap") { return "🎤" }
        if g.contains("news") { return "📰" }
        if g.contains("talk") { return "💬" }
        if g.contains("sport") { return "🏟️" }
        if g.contains("latin") { return "💃" }
        if g.contains("america") || g.contains("américa") { return "🌎" }
        if g.contains("culture") { return "🎭" }

        // Deterministic "fun" fallback so non-standard tags don't all look the same.
        let palette: [String] = [
            "🎧", "🎶", "🎼", "📻", "🎙️", "💿", "🪩", "✨", "🌙", "☕️",
            "🌿", "🌊", "🔥", "🧠", "🛰️", "🎹", "🥁", "🎺", "🎻", "🎸",
            "🪕", "🎷", "🪘", "🎤", "🔊", "🎛️", "🎚️", "📡", "📺", "📼",
            "🗺️", "🧭", "🌎", "🌍", "🌏", "🏙️", "🌃", "🚗", "🚇", "✈️",
            "🚀", "🧘", "🏃", "📚", "📝", "🧩", "🪄", "🧊", "🌈", "🌻",
            "🍀", "🍉", "🍫", "🍣", "🍜", "🍕", "🌮", "🥐", "🍵", "🥤"
        ]

        var h: Int = 0
        for u in g.unicodeScalars {
            h = (h &* 31) &+ Int(u.value)
        }
        let idx = abs(h) % palette.count
        return palette[idx]
    }

    private func genreTint(for genre: String) -> Color {
        let g = genre.lowercased()
        if g.contains("pop") { return .green }
        if g.contains("rock") { return .blue }
        if g.contains("elect") || g.contains("edm") { return .red }
        if g.contains("jazz") { return .purple }
        if g.contains("class") { return .indigo }
        if g.contains("hip") || g.contains("rap") { return .orange }
        return .gray
    }

    private var genreSummaries: [GenreSummary] {
        var counts: [String: Int] = [:]
        for station in stations {
            for label in station.moodGenreLabels {
                let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                counts[trimmed, default: 0] += 1
            }
        }
        return counts
            .map { GenreSummary(id: $0.key, name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func openStation(_ station: RadioStation) {
        AppLog.action("Open station from Home: \(station.id) \(station.name)")
        activeSheet = .station(station)
    }

    private var topCountries: [CountrySummary] { Array(countrySummaries.prefix(4)) }
    private var moreCountries: [CountrySummary] {
        let all = countrySummaries
        return all.count > 4 ? Array(all.dropFirst(4)) : []
    }

    private var topGenres: [GenreSummary] { Array(genreSummaries.prefix(3)) }
    private var moreGenres: [GenreSummary] {
        let all = genreSummaries
        return all.count > 3 ? Array(all.dropFirst(3)) : []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Nearby stations carousel
                if !stations.isEmpty {
                    Text("Nearby Stations")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(nearbyStations) { station in
                                Button {
                                    openStation(station)
                                } label: {
                                    NearbyStationCardView(station: station)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(station.name)
                                .accessibilityHint("Opens the station player")
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Countries
                if !countrySummaries.isEmpty {
                    SectionHeaderLink("Countries", destination: CountriesBrowserView(
                        countries: countrySummaries,
                        stations: $stations,
                        favorites: $favorites
                    ))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(topCountries) { c in
                            NavigationLink {
                                CountryStationsListView(country: c.name, stations: $stations, favorites: $favorites)
                            } label: {
                                CountryCardView(country: c)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !moreCountries.isEmpty {
                        DisclosureGroup(isExpanded: $countriesExpanded) {
                            VStack(spacing: 0) {
                                ForEach(moreCountries) { c in
                                    NavigationLink {
                                        CountryStationsListView(country: c.name, stations: $stations, favorites: $favorites)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(c.flagEmoji)
                                            Text(c.name)
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    Divider()
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("More Countries")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        .padding(.top, 4)
                    }
                }

                // Genres
                if !genreSummaries.isEmpty {
                    SectionHeaderLink("Genres", destination: GenresBrowserView(
                        genres: genreSummaries,
                        stations: $stations,
                        favorites: $favorites
                    ))

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(topGenres) { g in
                            NavigationLink {
                                GenreStationsListView(genre: g.name, stations: $stations, favorites: $favorites)
                            } label: {
                                GenreCardView(
                                    title: displayGenreName(g.name),
                                    icon: genreIcon(for: g.name),
                                    tint: genreTint(for: g.name)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if !moreGenres.isEmpty {
                        DisclosureGroup(isExpanded: $genresExpanded) {
                            VStack(spacing: 0) {
                                ForEach(moreGenres) { g in
                                    NavigationLink {
                                        GenreStationsListView(genre: g.name, stations: $stations, favorites: $favorites)
                                    } label: {
                                        HStack(spacing: 10) {
                                            Text(genreIcon(for: g.name))
                                            Text(displayGenreName(g.name))
                                                .foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    Divider()
                                }
                            }
                            .padding(.top, 6)
                        } label: {
                            Text("More Genres")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                        .padding(.top, 4)
                    }
                }

                // Keep the legacy "Places" browsing feature accessible without changing its behavior.
                NavigationLink {
                    PlacesListView(places: $places, stations: $stations, favorites: $favorites)
                } label: {
                    HStack {
                        Image(systemName: "list.bullet")
                        Text("Browse All (Filters)")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .accessibilityHint("Opens the full list view with filters for places and radio stations")
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        // This is the Places tab landing page (dashboard-style), so the large title should match the tab label.
        .navigationTitle("Places")
        .onAppear {
            AppLog.info("PlacesHomeView appeared")
            locationManager.requestOneShotLocation()
        }
        .onChange(of: activeSheet?.id) { _, _ in
            placeDetent = .height(360)
            stationDetent = .height(340)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .place(let place):
                PlaceMusicModalView(place: place, favorites: $favorites, detent: $placeDetent, onDelete: {
                    places.removeAll { $0.id == place.id }
                    activeSheet = nil
                })
                    .presentationDetents([.height(360), .medium], selection: $placeDetent)
            case .station(let station):
                StationMusicModalView(station: station, favorites: $favorites, detent: $stationDetent, onDelete: {
                    stations.removeAll { $0.id == station.id }
                    activeSheet = nil
                })
                    .presentationDetents([.height(340), .medium], selection: $stationDetent)
            }
        }
    }
}

private struct NearbyStationCardView: View {
    let station: RadioStation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            StationLogoView(logoURLString: station.logoURL)
                .frame(width: 92, height: 92)
                .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )

            Text(station.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(station.country)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: 150, alignment: .leading)
        .padding(12)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }
}

private struct CountryCardView: View {
    let country: CountrySummary

    var body: some View {
        VStack(spacing: 10) {
            Text(country.flagEmoji)
                .font(.system(size: 34))
            Text(country.name)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct GenreCardView: View {
    let title: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            Text(icon)
                .font(.system(size: 32))
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .padding(.vertical, 12)
        .background(tint.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// All countries browser screen (grid preview + list), matching the "Countries" screenshot style.
struct CountriesBrowserView: View {
    let countries: [CountrySummary]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var query: String = ""

    private var filtered: [CountrySummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return countries }
        return countries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var top: [CountrySummary] { Array(filtered.prefix(6)) }
    private var rest: [CountrySummary] { filtered.count > 6 ? Array(filtered.dropFirst(6)) : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(top) { c in
                        NavigationLink {
                            CountryStationsListView(country: c.name, stations: $stations, favorites: $favorites)
                        } label: {
                            CountryCardView(country: c)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !rest.isEmpty {
                    Text("More Countries")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(rest) { c in
                            NavigationLink {
                                CountryStationsListView(country: c.name, stations: $stations, favorites: $favorites)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(c.flagEmoji)
                                    Text(c.name)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .navigationTitle("Countries")
        .searchable(text: $query, prompt: "Search")
        .onChange(of: query) { _, newValue in
            AppLog.action("Countries search query: \(newValue)")
        }
    }
}

/// All genres browser screen (grid preview + list), matching the "Genres" card style.
struct GenresBrowserView: View {
    let genres: [GenreSummary]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var query: String = ""

    private func icon(for genre: String) -> String {
        let g = genre.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // Common genre shortcuts
        if g.contains("pop") { return "🍿" }
        if g.contains("rock") { return "🎸" }
        if g.contains("elect") || g.contains("edm") { return "🎛️" }
        if g.contains("jazz") { return "🎷" }
        if g.contains("class") { return "🎻" }
        if g.contains("hip") || g.contains("rap") { return "🎤" }
        if g.contains("news") { return "📰" }
        if g.contains("talk") { return "💬" }
        if g.contains("sport") { return "🏟️" }
        if g.contains("latin") { return "💃" }
        if g.contains("america") || g.contains("américa") { return "🌎" }
        if g.contains("culture") { return "🎭" }
        if g.contains("stream") { return "📡" }

        // Deterministic "fun" fallback so non-standard tags don't all look the same.
        let palette: [String] = [
            "🎧", "🎶", "🎼", "📻", "🎙️", "💿", "🪩", "✨", "🌙", "☕️",
            "🌿", "🌊", "🔥", "🧠", "🛰️", "🎹", "🥁", "🎺", "🎻", "🎸",
            "🪕", "🎷", "🪘", "🎤", "🔊", "🎛️", "🎚️", "📡", "📺", "📼",
            "🗺️", "🧭", "🌎", "🌍", "🌏", "🏙️", "🌃", "🚗", "🚇", "✈️",
            "🚀", "🧘", "🏃", "📚", "📝", "🧩", "🪄", "🧊", "🌈", "🌻",
            "🍀", "🍉", "🍫", "🍣", "🍜", "🍕", "🌮", "🥐", "🍵", "🥤"
        ]

        var h: Int = 0
        for u in g.unicodeScalars {
            h = (h &* 31) &+ Int(u.value)
        }
        let idx = abs(h) % palette.count
        return palette[idx]
    }

    private func tint(for genre: String) -> Color {
        let g = genre.lowercased()
        if g.contains("pop") { return .green }
        if g.contains("rock") { return .blue }
        if g.contains("elect") || g.contains("edm") { return .red }
        if g.contains("jazz") { return .purple }
        if g.contains("class") { return .indigo }
        if g.contains("hip") || g.contains("rap") { return .orange }
        return .gray
    }

    private var filtered: [GenreSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return genres }
        // Match on both the raw label and the cleaned display label.
        return genres.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed) ||
            displayGenreName($0.name).localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var top: [GenreSummary] { Array(filtered.prefix(9)) }
    private var rest: [GenreSummary] { filtered.count > 9 ? Array(filtered.dropFirst(9)) : [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(top) { g in
                        NavigationLink {
                            GenreStationsListView(genre: g.name, stations: $stations, favorites: $favorites)
                        } label: {
                            GenreCardView(title: displayGenreName(g.name), icon: icon(for: g.name), tint: tint(for: g.name))
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !rest.isEmpty {
                    Text("More Genres")
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        ForEach(rest) { g in
                            NavigationLink {
                                GenreStationsListView(genre: g.name, stations: $stations, favorites: $favorites)
                            } label: {
                                HStack(spacing: 10) {
                                    Text(icon(for: g.name))
                                    Text(displayGenreName(g.name))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
        }
        .navigationTitle("Genres")
        .searchable(text: $query, prompt: "Search")
        .onChange(of: query) { _, newValue in
            AppLog.action("Genres search query: \(newValue)")
        }
    }
}

/// Station list filtered by a single country (card rows + favorite hearts).
struct CountryStationsListView: View {
    let country: String
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var searchText: String = ""
    @State private var scope: ListScope = .all

    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    private var filteredStations: [RadioStation] {
        let base = stations.filter { $0.country == country }
        let scoped: [RadioStation]
        if scope == .favorites {
            scoped = base.filter { favorites.contains(stationFavoriteID($0)) }
        } else {
            scoped = base
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = q.isEmpty ? scoped : scoped.filter { $0.name.localizedCaseInsensitiveContains(q) }
        return searched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if filteredStations.isEmpty {
                ContentUnavailableView("No stations found", systemImage: "dot.radiowaves.left.and.right")
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredStations) { station in
                    NavigationLink {
                        StationMusicModalView(station: station, favorites: $favorites)
                    } label: {
                        StationRow(station: station, favorites: $favorites)
                    }
                    .cardListRowStyle()
                }
            }
        }
        .navigationTitle(country)
        .searchable(text: $searchText, prompt: "Search stations")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Scope", selection: $scope) {
                    ForEach(ListScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityLabel("List scope")
            }
        }
        .onChange(of: scope) { _, newValue in
            AppLog.action("Country stations scope changed: \(newValue.rawValue) (\(country))")
        }
    }
}

/// Station list filtered by a single genre (card rows + favorite hearts).
struct GenreStationsListView: View {
    let genre: String
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var searchText: String = ""
    @State private var scope: ListScope = .all

    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    private var filteredStations: [RadioStation] {
        let base = stations.filter { $0.moodGenreLabels.contains(genre) }
        let scoped: [RadioStation]
        if scope == .favorites {
            scoped = base.filter { favorites.contains(stationFavoriteID($0)) }
        } else {
            scoped = base
        }

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched = q.isEmpty ? scoped : scoped.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.country.localizedCaseInsensitiveContains(q) }
        return searched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        List {
            if filteredStations.isEmpty {
                ContentUnavailableView("No stations found", systemImage: "dot.radiowaves.left.and.right")
                    .listRowSeparator(.hidden)
            } else {
                ForEach(filteredStations) { station in
                    NavigationLink {
                        StationMusicModalView(station: station, favorites: $favorites)
                    } label: {
                        StationRow(station: station, favorites: $favorites)
                    }
                    .cardListRowStyle()
                }
            }
        }
        .navigationTitle(displayGenreName(genre))
        .searchable(text: $searchText, prompt: "Search stations")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Scope", selection: $scope) {
                    ForEach(ListScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityLabel("List scope")
            }
        }
        .onChange(of: scope) { _, newValue in
            AppLog.action("Genre stations scope changed: \(newValue.rawValue) (\(genre))")
        }
    }
}



/// Drives the animated "fly to random station" camera sequence on the map.
struct RandomStationFlightRequest: Identifiable {
    let id = UUID()
    let station: RadioStation
    let startCoordinate: CLLocationCoordinate2D
    let targetCoordinate: CLLocationCoordinate2D
    let overviewRegion: MKCoordinateRegion
    let finalRegion: MKCoordinateRegion
}

/// Full-screen map tab with clickable pins.
/// Tapping a pin opens the same modal "Place Card" used elsewhere.
struct PlacesMapTabView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var activeSheet: ActiveSheet? = nil
    // Control sheet height so we can tweak layout only for the compact (not pulled out) state.
    // Slightly taller compact detents so content doesn't look clipped under the
    // grabber/rounded corners on iPhone in the compact state.
    @State private var placeDetent: PresentationDetent = .height(360)
    @State private var stationDetent: PresentationDetent = .height(340)

    @State private var stationSearchText: String = ""

    // Persisted map style selection (shared across map views).
    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = true

    // iPad TabView shows the tab bar at the top, which can overlap our custom map overlay.
    // Add a small extra top offset only on iPad so the search bar + buttons sit below the top tab bar.
    private var topControlsOffset: CGFloat {
        // Tuned so the search bar sits just under the iPad top tab strip without leaving an excessive gap.
        UIDevice.current.userInterfaceIdiom == .pad ? 28 : 0
    }

    // On iPhone we intentionally nudge the cluster upward to sit closer to the Dynamic Island.
    // On iPad (top tab bar), keep it within the safe area to avoid overlapping the tab strip.
    private var topClusterNudge: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 0 : -50
    }

    // MapKit place search (not limited to existing pins).
    @State private var isSearchingPlaces: Bool = false
    @State private var showPlaceSearchSheet: Bool = false
    @State private var placeSearchQuery: String = ""
    @State private var placeSearchResults: [MKMapItem] = []
    @State private var placeSearchError: String? = nil
    @State private var showSleepTimerSheet: Bool = false
    @ObservedObject private var sleepTimer = SleepTimerManager.shared


    @State private var region: MKCoordinateRegion = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 35.0, longitude: 0.0), span: MKCoordinateSpan(latitudeDelta: 80.0, longitudeDelta: 80.0))
    @State private var pendingFlightRequest: RandomStationFlightRequest? = nil
    @State private var pendingRandomStationSheetWorkItem: DispatchWorkItem? = nil
    @StateObject private var locationManager = LocationManager()
    @ObservedObject private var audio = AudioManager.shared

    private var trimmedStationQuery: String {
        stationSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Stations filtered by the current query. Used for both map pins and the search results card.
    private var matchedStations: [RadioStation] {
        guard !trimmedStationQuery.isEmpty else { return stations }
        return stations.filter { $0.name.localizedCaseInsensitiveContains(trimmedStationQuery) }
    }

    /// Places filtered by the current query. Used for both map pins and the search results card.
    private var matchedPlaces: [Place] {
        guard !trimmedStationQuery.isEmpty else { return places }
        return places.filter { $0.name.localizedCaseInsensitiveContains(trimmedStationQuery) }
    }

    /// Formats a place's address into a user-friendly single line.
    private func formattedAddress(for placemark: MKPlacemark) -> String {
        var parts: [String] = []
        if let name = placemark.name { parts.append(name) }
        if let city = placemark.locality { parts.append(city) }
        if let state = placemark.administrativeArea { parts.append(state) }
        if let country = placemark.country { parts.append(country) }
        // Avoid repeating the name twice.
        let unique = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
        return unique.joined(separator: ", ")
    }

    /// Starts a MapKit place search for the provided query text.
    private func startPlaceSearch(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        placeSearchQuery = trimmed
        placeSearchError = nil
        placeSearchResults = []
        isSearchingPlaces = true
        showPlaceSearchSheet = true

        AppLog.action("Search places: \(trimmed)")
        AppLog.info("Map search region center=(\(region.center.latitude), \(region.center.longitude)) span=(\(region.span.latitudeDelta), \(region.span.longitudeDelta))")

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        // Bias results around the current visible region.
        request.region = region

        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                isSearchingPlaces = false
                if let error = error {
                    AppLog.info("Map search failed for \(trimmed): \(error.localizedDescription)")
                    placeSearchError = error.localizedDescription
                    placeSearchResults = []
                    return
                }
                placeSearchResults = response?.mapItems ?? []
                AppLog.info("Map search results for \(trimmed): \(placeSearchResults.count) items")
                if let first = placeSearchResults.first {
                    AppLog.dump("Map search first result", [
                        "name": first.name ?? "",
                        "lat": first.placemark.coordinate.latitude,
                        "lon": first.placemark.coordinate.longitude
                    ] as [String: Any])
                }
                if placeSearchResults.isEmpty {
                    placeSearchError = "No places found."
                }
            }
        }
    }

    /// Creates and persists a new user place pin from a selected search result.
    private func addPlacePin(from mapItem: MKMapItem) {
        let coord = mapItem.placemark.coordinate
        guard coord.latitude.isFinite, coord.longitude.isFinite else { return }

        let name = mapItem.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let placeName = (name?.isEmpty == false) ? name! : placeSearchQuery
        let addr = formattedAddress(for: mapItem.placemark)

        AppLog.action("Add place pin from search: \(placeName)")
        AppLog.dump("Map search selection", [
            "name": placeName,
            "address": addr,
            "lat": coord.latitude,
            "lon": coord.longitude
        ] as [String: Any])

        // Create a user-added pin. We store it in UserDefaults (via RootView onChange).
        let newPlace = Place(
            id: "user_" + UUID().uuidString,
            name: placeName,
            category: .services,
            subtitle: "Added from search",
            address: addr,
            hours: "",
            notes: "",
            latitude: coord.latitude,
            longitude: coord.longitude
        )

        // Avoid duplicates if user taps the same result multiple times.
        if !places.contains(where: { $0.name == newPlace.name && abs($0.latitude - newPlace.latitude) < 0.00001 && abs($0.longitude - newPlace.longitude) < 0.00001 }) {
            places.append(newPlace)
        }

        // Center map on the selected place and open its modal.
        region = MKCoordinateRegion(center: coord, span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6))
        activeSheet = .place(newPlace)
        showPlaceSearchSheet = false
    }

    // ActiveSheet defines custom cases and helpers used by this feature area.
    enum ActiveSheet: Identifiable {
        case place(Place)
        case station(RadioStation)

        var id: String {
            switch self {
            case .place(let p): return "place_" + p.id
            case .station(let s): return "station_" + s.id
            }
        }
    }

    /// Selects a random station and animates the map camera to its location.
    private func flyToRandomStation() {
        let candidates = trimmedStationQuery.isEmpty ? stations : matchedStations
        guard let picked = candidates.randomElement() else {
            AppLog.info("Random station requested, but no stations matched the current filters")
            return
        }

        // Ensure we have the freshest possible user coordinate.
        locationManager.requestOneShotLocation()

        let startCoord = locationManager.coordinate ?? region.center
        let targetCoord = CLLocationCoordinate2D(latitude: picked.latitude, longitude: picked.longitude)

        // Compute an "overview" span that can show both points during the flight.
        let dLat = abs(startCoord.latitude - targetCoord.latitude)
        let rawLonDelta = abs(startCoord.longitude - targetCoord.longitude)
        let wrappedLonDelta = min(rawLonDelta, 360 - rawLonDelta)
        let maxDelta = max(dLat, wrappedLonDelta)
        let overviewDelta = min(max(maxDelta * 2.35 + 2.0, 10.0), 145.0)

        let overviewRegion = MKCoordinateRegion(
            center: startCoord,
            span: MKCoordinateSpan(latitudeDelta: overviewDelta, longitudeDelta: overviewDelta)
        )
        let finalRegion = MKCoordinateRegion(
            center: targetCoord,
            span: MKCoordinateSpan(latitudeDelta: 0.9, longitudeDelta: 0.9)
        )

        let request = RandomStationFlightRequest(
            station: picked,
            startCoordinate: startCoord,
            targetCoordinate: targetCoord,
            overviewRegion: overviewRegion,
            finalRegion: finalRegion
        )

        AppLog.action("Random station selected for animated flyover: \(picked.id) \(picked.name)")
        AppLog.dump("Random station flyover", [
            "fromLat": startCoord.latitude,
            "fromLon": startCoord.longitude,
            "toLat": targetCoord.latitude,
            "toLon": targetCoord.longitude,
            "overviewDelta": overviewDelta,
            "reduceMotion": accessibilityReduceMotion
        ] as [String: Any])

        pendingFlightRequest = request

        pendingRandomStationSheetWorkItem?.cancel()
        let presentDelay: TimeInterval = accessibilityReduceMotion ? 0.15 : 2.3
        let workItem = DispatchWorkItem {
            activeSheet = .station(picked)
            pendingRandomStationSheetWorkItem = nil
        }
        pendingRandomStationSheetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + presentDelay, execute: workItem)
    }


    var body: some View {
        Group {
            if places.isEmpty && stations.isEmpty {
                EmptyStateView(
                    title: "No items loaded",
                    systemImage: "exclamationmark.triangle",
                    message: "Check that places.json and stations.json are included in your app bundle."
                )
            } else {
                PlacesStationsOverviewMapView(
                    places: matchedPlaces,
                    stations: matchedStations,
                    activeSheet: $activeSheet,
                    region: $region,
                    flightRequest: $pendingFlightRequest
                )
                // Let the map truly fill the whole screen (behind the Tab Bar).
                // The mini player is inserted from RootView via `safeAreaInset`,
                // so it will stay above the Tab Bar and not overlap it.
                .ignoresSafeArea(edges: [.top, .bottom])
            }
        }
        // A dedicated search bar for the Map tab.
        // It filters both radio stations and place pins by name.
        .safeAreaInset(edge: .top, spacing: 0) {
            ZStack(alignment: .top) {
                VStack(spacing: 6) {
                    MapStationSearchBar(text: $stationSearchText, onSubmit: {
                        // Keep the on-screen search results card focused on local content,
                        // while still allowing MapKit place search when the user submits.
                        startPlaceSearch(for: stationSearchText)
                    })

                    HStack {
                        Button {
                            mapIsSatellite.toggle()
                            AppLog.action("Map style toggled: \(mapIsSatellite ? "satellite" : "standard")")
                        } label: {
                            Image(systemName: mapIsSatellite ? "globe.americas.fill" : "map.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(mapIsSatellite ? "Switch to standard map" : "Switch to satellite map")
                        .accessibilityHint("Toggles the map appearance")

                        Button {
                            AppLog.action("Random station button tapped")
                            flyToRandomStation()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 36, height: 36)
                                .background(.thinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Random station")
                        .accessibilityHint(accessibilityReduceMotion ? "Jump to a random radio station on the map" : "Animate to a random radio station on the map")

                        Spacer()
                        MapCenterControls(
                            stations: stations,
                            region: $region,
                            locationManager: locationManager,
                            onTimerTap: {
                                AppLog.action("Sleep timer sheet opened")
                                showSleepTimerSheet = true
                            }
                        )
                    }

                    // Search results card: appears only when the query is non-empty.
                    MapStationSearchResultsCard(
                        query: trimmedStationQuery,
                        stations: matchedStations,
                        places: matchedPlaces,
                        onSelectStation: { station in
                            AppLog.action("Map inline search selected station: \(station.id) \(station.name)")
                            activeSheet = .station(station)
                        },
                        onSelectPlace: { place in
                            AppLog.action("Map inline search selected place: \(place.id) \(place.name)")
                            AppLog.dump("Map inline search selected place coordinate", [
                                "lat": place.latitude,
                                "lon": place.longitude
                            ])
                            region = MKCoordinateRegion(
                                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                span: MKCoordinateSpan(latitudeDelta: 0.6, longitudeDelta: 0.6)
                            )
                            activeSheet = .place(place)
                        }
                    )
                }
                // Keep controls tight to the top safe area (right under the Dynamic Island).
                .padding(.top, topControlsOffset)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

                // Countdown chip overlays under the search bar without shifting other controls.
                if sleepTimer.isActive {
                    HStack {
                        Spacer()
                        Button {
                            AppLog.action("Sleep timer countdown chip tapped: cancel")
                            sleepTimer.cancel()
                        } label: {
                            SleepTimerCountdownChip(remainingText: sleepTimer.formattedRemaining())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel sleep timer")
                        .accessibilityValue(sleepTimer.formattedRemaining())
                        .accessibilityHint("Double tap to cancel the sleep timer")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 52 + topControlsOffset)
                    .transition(.opacity)
                }
            }
            // Pull the whole control cluster slightly into the top unsafe area so it
            // visually hugs the Dynamic Island / status bar.
            .padding(.top, topClusterNudge)
        }
        .onAppear {
            locationManager.requestAuthorizationIfNeeded()
        }
        .onChange(of: activeSheet?.id) { _, _ in
            // Always start sheets in the compact detent.
            placeDetent = .height(360)
            stationDetent = .height(340)
        }
        .sheet(isPresented: $showSleepTimerSheet) {
            SleepTimerSheet(isPresented: $showSleepTimerSheet)
        }
        .sheet(isPresented: $showPlaceSearchSheet) {
            PlaceSearchResultsSheet(
                query: placeSearchQuery,
                results: placeSearchResults,
                isSearching: isSearchingPlaces,
                errorMessage: placeSearchError,
                onSelect: { item in
                    addPlacePin(from: item)
                },
                onDismiss: {
                    showPlaceSearchSheet = false
                }
            )
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .place(let place):
                PlaceMusicModalView(place: place, favorites: $favorites, detent: $placeDetent, onDelete: {
                    places.removeAll { $0.id == place.id }
                    activeSheet = nil
                })
                    .presentationDetents([.height(360), .medium], selection: $placeDetent)
            case .station(let station):
                StationMusicModalView(station: station, favorites: $favorites, detent: $stationDetent, onDelete: {
                    stations.removeAll { $0.id == station.id }
                    activeSheet = nil
                })
                    .presentationDetents([.height(340), .medium], selection: $stationDetent)
            }
        }
        .onDisappear {
            pendingRandomStationSheetWorkItem?.cancel()
            pendingRandomStationSheetWorkItem = nil
        }
    }
}


// MARK: - Recent tab

// RecentTabView renders a custom interface component for this feature area.
struct RecentTabView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    /// Callback used to open the Help sheet from the toolbar.
    let onHelp: () -> Void

    @EnvironmentObject private var recents: RecentManager

    @State private var activeSheet: ActiveSheet? = nil

    // Control sheet height so we can tweak layout only for the compact (not pulled out) state.
    @State private var placeDetent: PresentationDetent = .height(360)
    @State private var stationDetent: PresentationDetent = .height(340)

    /// Top segmented control mode for the Favorites tab.
    private enum FavoritesMode: String, CaseIterable, Identifiable {
        case favorites = "Favorites"
        case recent = "Recent"
        var id: String { rawValue }
    }

    @State private var mode: FavoritesMode = .favorites

    /// Category chips for the Favorites mode (mirrors the Places tab chips, but without the radio discovery filters).
    private enum FavoritesCategoryFilter: Hashable {
        case all
        case place(PlaceCategory)
        case radio

        var label: String {
            switch self {
            case .all: return "All Categories"
            case .place(let c): return c.displayName
            case .radio: return "Radio"
            }
        }
    }

    @State private var favoritesCategoryFilter: FavoritesCategoryFilter = .all

    // ActiveSheet defines custom cases and helpers used by this feature area.
    enum ActiveSheet: Identifiable {
        case place(Place)
        case station(RadioStation)

        var id: String {
            switch self {
            case .place(let p): return "place_" + p.id
            case .station(let s): return "station_" + s.id
            }
        }
    }

    private var recentItems: [RecentItem] { recents.items }

    /// Computes the favorites identifier used for a station.
    private func stationFavoriteID(_ station: RadioStation) -> String { "station_" + station.id }

    private var favoritePlaces: [Place] {
        places
            .filter { favorites.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var favoriteStations: [RadioStation] {
        stations
            .filter { favorites.contains(stationFavoriteID($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var placeCategories: [PlaceCategory] {
        Array(Set(places.map { $0.effectiveCategory }))
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredFavoritePlaces: [Place] {
        switch favoritesCategoryFilter {
        case .all:
            return favoritePlaces
        case .radio:
            return []
        case .place(let c):
            return favoritePlaces.filter { $0.effectiveCategory == c }
        }
    }

    private var filteredFavoriteStations: [RadioStation] {
        switch favoritesCategoryFilter {
        case .all, .radio:
            return favoriteStations
        case .place:
            return []
        }
    }

    private func chipButton(title: String, isSelected: Bool, action: @escaping () -> Void, hint: String) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                .clipShape(Capsule())
                .fixedSize(horizontal: true, vertical: false)
        }
        .accessibilityLabel(title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint(hint)
    }

    private var favoritesCategoryChipsCard: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 8) {
                chipButton(
                    title: FavoritesCategoryFilter.all.label,
                    isSelected: favoritesCategoryFilter == .all,
                    action: { favoritesCategoryFilter = .all },
                    hint: "Shows your favorited places and radio stations"
                )

                ForEach(placeCategories, id: \.self) { cat in
                    chipButton(
                        title: cat.displayName,
                        isSelected: favoritesCategoryFilter == .place(cat),
                        action: { favoritesCategoryFilter = .place(cat) },
                        hint: "Filters your favorites to the \(cat.displayName) category"
                    )
                }

                chipButton(
                    title: FavoritesCategoryFilter.radio.label,
                    isSelected: favoritesCategoryFilter == .radio,
                    action: { favoritesCategoryFilter = .radio },
                    hint: "Filters your favorites to radio stations"
                )
            }
            .padding(.vertical, 4)
            .fixedSize(horizontal: true, vertical: false)
            .buttonStyle(.plain)
        }
        .scrollIndicators(.visible)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
    }

    private var favoritesEmpty: Bool { favoritePlaces.isEmpty && favoriteStations.isEmpty }

    // Removes recent item for this feature.
    private func removeRecentItem(_ item: RecentItem) {
        recents.remove(kind: item.kind, itemID: item.itemID)
        if activeSheet?.id == item.id {
            activeSheet = nil
        }
    }

    /// Resolves the best available logo URL for a recent station item.
    private func resolvedLogoURL(for item: RecentItem) -> String? {
        guard item.kind == .station else { return nil }
        let fromStations = stations.first(where: { $0.id == item.itemID })?.logoURL
        let candidates: [String?] = [fromStations, item.logoURL]
        for candidate in candidates {
            if let s = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return nil
    }

    /// Card-like row for recent items (keeps Recents behavior while matching the new card styling).
    private func recentCardRow(for item: RecentItem) -> some View {
        HStack(spacing: 12) {
            if item.kind == .station {
                StationLogoView(logoURLString: resolvedLogoURL(for: item))
                    .frame(width: 34, height: 34)
            } else {
                Image(systemName: "music.note")
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
    private func favoriteStationCardRow(_ station: RadioStation) -> some View {
        let favoriteID = stationFavoriteID(station)
        let isFavorite = favorites.contains(favoriteID)

        return HStack(spacing: 12) {
            AlamofireStationLogoView(logoURLString: station.logoURL)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(station.country)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Radio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                if isFavorite {
                    favorites.remove(favoriteID)
                } else {
                    favorites.insert(favoriteID)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .imageScale(.large)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func favoritePlaceCardRow(_ place: Place) -> some View {
        let isFavorite = favorites.contains(place.id)

        return HStack(spacing: 12) {
            Image(systemName: place.iconSystemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(place.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(place.effectiveCategory.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                if isFavorite {
                    favorites.remove(place.id)
                } else {
                    favorites.insert(place.id)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .imageScale(.large)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }


    private var modePicker: some View {
            Picker("Favorites view mode", selection: $mode) {
                ForEach(FavoritesMode.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Favorites view mode")
            .accessibilityValue(mode.rawValue)
            .accessibilityHint("Switch between your favorites and recent items")
        }

    var body: some View {
        NavigationStack {
            List {
                if mode == .favorites {
                    if favoritesEmpty {
                        ContentUnavailableView("No favorites yet", systemImage: "star")
                            .listRowSeparator(.hidden)
                    } else {
                        // Category tags (Food / Housing / etc.) like the Places list, without the discovery filters.
                        favoritesCategoryChipsCard
                            .cardListRowStyle()

                        let favStations = filteredFavoriteStations
                        let favPlaces = filteredFavoritePlaces

                        if favStations.isEmpty && favPlaces.isEmpty {
                            ContentUnavailableView("No favorites in this category", systemImage: "star")
                                .listRowSeparator(.hidden)
                        } else {
                            switch favoritesCategoryFilter {
                            case .all:
                                if !favStations.isEmpty {
                                    Section("Radio") {
                                        ForEach(favStations) { station in
                                            Button {
                                                activeSheet = .station(station)
                                            } label: {
                                                StationRow(station: station, favorites: $favorites, showsDisclosure: true)
                                            }
                                            .buttonStyle(.plain)
                                            .cardListRowStyle()
                                            .accessibilityHint("Opens the station player sheet. Use the heart button to remove from favorites.")
                                        }
                                    }
                                    .textCase(nil)
                                }

                                if !favPlaces.isEmpty {
                                    Section("Places") {
                                        ForEach(favPlaces, id: \.listRefreshID) { place in
                                            Button {
                                                activeSheet = .place(place)
                                            } label: {
                                                PlaceRow(place: place, favorites: $favorites, showsDisclosure: true)
                                            }
                                            .buttonStyle(.plain)
                                            .cardListRowStyle()
                                            .accessibilityHint("Opens the place player sheet. Use the heart button to remove from favorites.")
                                        }
                                    }
                                    .textCase(nil)
                                }

                            case .radio:
                                ForEach(favStations) { station in
                                    Button {
                                        activeSheet = .station(station)
                                    } label: {
                                        StationRow(station: station, favorites: $favorites, showsDisclosure: true)
                                    }
                                    .buttonStyle(.plain)
                                    .cardListRowStyle()
                                    .accessibilityHint("Opens the station player sheet. Use the heart button to remove from favorites.")
                                }

                            case .place:
                                ForEach(favPlaces, id: \.listRefreshID) { place in
                                    Button {
                                        activeSheet = .place(place)
                                    } label: {
                                        PlaceRow(place: place, favorites: $favorites, showsDisclosure: true)
                                    }
                                    .buttonStyle(.plain)
                                    .cardListRowStyle()
                                    .accessibilityHint("Opens the place player sheet. Use the heart button to remove from favorites.")
                                }
                            }
                        }
                    }
                } else {
                    if recentItems.isEmpty {
                        ContentUnavailableView("No recent items", systemImage: "clock")
                            .listRowSeparator(.hidden)
                    } else {
                        // Recent mode already uses a large page title ("Recent"), so we
                        // intentionally omit the section header to avoid a duplicate subtitle.
                        Section {
                            ForEach(recentItems) { item in
                                Button {
                                    switch item.kind {
                                    case .place:
                                        if let p = places.first(where: { $0.id == item.itemID }) {
                                            activeSheet = .place(p)
                                        }
                                    case .station:
                                        if let s = stations.first(where: { $0.id == item.itemID }) {
                                            activeSheet = .station(s)
                                        }
                                    }
                                } label: {
                                    recentCardRow(for: item)
                                }
                                .buttonStyle(.plain)
                                .cardListRowStyle()
                                .contextMenu {
                                    Button(role: .destructive) {
                                        removeRecentItem(item)
                                    } label: {
                                        Label("Remove from Recent", systemImage: "trash")
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        removeRecentItem(item)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                                .accessibilityHint("Opens the saved detail view. Swipe or use actions to remove this item from recent.")
                                .accessibilityAction(named: Text("Remove from recent")) {
                                    removeRecentItem(item)
                                }
                            }
                        }
                        .textCase(nil)
                    }
                }
            }
            // Dynamic title so the Recent mode shows "Recent" while Favorites mode stays "Favorites".
            .navigationTitle(mode == .recent ? "Recent" : "Favorites")
                        .toolbar {
                ToolbarItem(placement: .principal) {
                    modePicker
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onHelp) {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Help")
                }

                if mode == .recent && !recentItems.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear") {
                            AppLog.action("Cleared recent items")
                            recents.clear()
                        }
                    }
                }
            }
            .onChange(of: mode) { _, newValue in
                AppLog.action("Favorites tab mode changed: \(newValue.rawValue)")
            }
            .onChange(of: favoritesCategoryFilter) { _, newValue in
                AppLog.action("Favorites category filter changed: \(newValue.label)")
            }
            .onChange(of: activeSheet?.id) { _, _ in
                placeDetent = .height(360)
                stationDetent = .height(340)
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .place(let place):
                    PlaceMusicModalView(place: place, favorites: $favorites, detent: $placeDetent, onDelete: {
                        places.removeAll { $0.id == place.id }
                        activeSheet = nil
                    })
                        .presentationDetents([.height(360), .medium], selection: $placeDetent)
                case .station(let station):
                    StationMusicModalView(station: station, favorites: $favorites, detent: $stationDetent, onDelete: {
                        stations.removeAll { $0.id == station.id }
                        activeSheet = nil
                    })
                        .presentationDetents([.height(340), .medium], selection: $stationDetent)
                }
            }
        }
    }
}


/// Map-only search bar to filter radio stations and place pins by name.
struct MapStationSearchBar: View {
    @Binding var text: String
    var onSubmit: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)

            TextField("Search radio stations or places", text: $text)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .submitLabel(.search)
                .accessibilityLabel("Search radio stations or places")
                .accessibilityHint("Filters the map and shows matching places and radio stations")
                .onSubmit {
                    onSubmit?()
                }

            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button {
                    AppLog.action("Map search cleared")
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Clears the current map search query")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }
}

/// Small map controls shown on the Map tab.
/// - Center on user location
/// - Center on the currently playing radio station
struct MapCenterControls: View {
    let stations: [RadioStation]
    // This map view owns its region (no parent binding)
    @Binding var region: MKCoordinateRegion
    @ObservedObject var locationManager: LocationManager
    let onTimerTap: () -> Void

    @ObservedObject private var audio = AudioManager.shared

    /// Updates the current map region to center on a coordinate with a specified span.
    private func setRegion(center: CLLocationCoordinate2D, delta: Double) {
        guard center.latitude.isFinite, center.longitude.isFinite else { return }
        region = MKCoordinateRegion(center: center, span: MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta))
    }

    private var currentlyPlayingStation: RadioStation? {
        guard let url = audio.currentStreamURLString else { return nil }
        return stations.first(where: { $0.streamURL == url })
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                AppLog.action("Center on my location tapped")
                locationManager.requestAuthorizationIfNeeded()
                locationManager.requestOneShotLocation()
                if let coord = locationManager.coordinate {
                    AppLog.dump("Center on my location coordinate", [
                        "lat": coord.latitude,
                        "lon": coord.longitude
                    ])
                    setRegion(center: coord, delta: 0.8)
                } else {
                    AppLog.info("Center on my location: coordinate unavailable yet")
                }
            } label: {
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Center on my location")
            .accessibilityHint("Requests your location and centers the map")

            Button {
                AppLog.action("Sleep timer button tapped")
                onTimerTap()
            } label: {
                Image(systemName: "zzz")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sleep timer")
            .accessibilityHint("Opens the sleep timer settings")


            Button {
                if let station = currentlyPlayingStation {
                    AppLog.action("Center on currently playing station: \(station.id) \(station.name)")
                    setRegion(center: CLLocationCoordinate2D(latitude: station.latitude, longitude: station.longitude), delta: 10)
                } else {
                    AppLog.info("Center on currently playing station tapped with no active station")
                }
            } label: {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(.thinMaterial, in: Circle())
                    .opacity(currentlyPlayingStation == nil ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(currentlyPlayingStation == nil)
            .accessibilityLabel("Center on currently playing station")
            .accessibilityHint("Centers the map on the station that is currently playing")
        }
    }
}

/// A small results card shown under the map's search bar.
/// - Only appears when the query is non-empty (after trimming).
/// - If there are no matches, shows a friendly "No matching content found" message.
/// - If there are matches, lists both place pins and radio stations.
struct MapStationSearchResultsCard: View {
    let query: String
    let stations: [RadioStation]
    let places: [Place]
    let onSelectStation: (RadioStation) -> Void
    let onSelectPlace: (Place) -> Void

    private var trimmed: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visiblePlaces: [Place] {
        Array(places.prefix(4))
    }

    private var visibleStations: [RadioStation] {
        Array(stations.prefix(4))
    }

    var body: some View {
        if trimmed.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                if visiblePlaces.isEmpty && visibleStations.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        Text("No matching content found")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 14)
                        Spacer(minLength: 0)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if !visiblePlaces.isEmpty {
                                Text("Places")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)

                                ForEach(Array(visiblePlaces.enumerated()), id: \.element.id) { idx, place in
                                    Button {
                                        onSelectPlace(place)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: place.iconSystemName)
                                                .foregroundColor(.secondary)
                                                .frame(width: 28, height: 28)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(place.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)

                                                Text(place.subtitle.isEmpty ? place.effectiveCategory.displayName : place.subtitle)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Place result: \(place.name)")
                                    .accessibilityValue(place.effectiveCategory.displayName)
                                    .accessibilityHint("Opens the place details")

                                    if idx != visiblePlaces.count - 1 {
                                        Divider()
                                            .padding(.leading, 12 + 28 + 12)
                                    }
                                }

                                if places.count > visiblePlaces.count {
                                    Text("+ \(places.count - visiblePlaces.count) more places")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                }
                            }

                            if !visiblePlaces.isEmpty && !visibleStations.isEmpty {
                                Divider()
                                    .padding(.vertical, 4)
                            }

                            if !visibleStations.isEmpty {
                                Text("Radio stations")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.top, 10)
                                    .padding(.bottom, 4)

                                ForEach(Array(visibleStations.enumerated()), id: \.element.id) { idx, station in
                                    Button {
                                        onSelectStation(station)
                                    } label: {
                                        HStack(spacing: 12) {
                                            StationLogoView(logoURLString: station.logoURL)
                                                .frame(width: 28, height: 28)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(station.name)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.primary)
                                                    .lineLimit(1)
                                                Text(station.country)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }

                                            Spacer(minLength: 0)
                                            Image(systemName: "chevron.right")
                                                .font(.caption.weight(.semibold))
                                                .foregroundColor(.secondary)
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Radio station result: \(station.name)")
                                    .accessibilityValue(station.country)
                                    .accessibilityHint("Opens the station details")

                                    if idx != visibleStations.count - 1 {
                                        Divider()
                                            .padding(.leading, 12 + 28 + 12)
                                    }
                                }

                                if stations.count > visibleStations.count {
                                    Text("+ \(stations.count - visibleStations.count) more stations")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }
}

/// Small logo view used in the map's search results card.
/// Falls back to a default radio icon if the URL is missing or fails.
struct StationLogoView: View {
    let logoURLString: String?

    var body: some View {
        AlamofireStationLogoView(logoURLString: logoURLString)
    }
}

// MARK: - Place Search Results (MapKit)

/// A sheet that shows MapKit place search results, allowing the user to add a new pin.
///
/// This is triggered when the user submits the Map tab search bar. The on-map
/// search results card continues to show local place-pin and radio-station matches.
struct PlaceSearchResultsSheet: View {
    let query: String
    let results: [MKMapItem]
    let isSearching: Bool
    let errorMessage: String?
    let onSelect: (MKMapItem) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if isSearching {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Searching…")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding()
                } else if let msg = errorMessage, results.isEmpty {
                    ContentUnavailableView(msg, systemImage: "magnifyingglass")
                } else {
                    List {
                        ForEach(results, id: \.self) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.name ?? "Unnamed place")
                                        .font(.headline)
                                    if let title = item.placemark.title, !title.isEmpty {
                                        Text(title)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { onDismiss() }
                }
            }
        }
    }
}

/// Small overview map used to preview pins and station locations in list contexts.
struct PlacesStationsOverviewMapView: View {
    let places: [Place]
    let stations: [RadioStation]
    @Binding var activeSheet: PlacesMapTabView.ActiveSheet?
    @Binding var flightRequest: RandomStationFlightRequest?

    // Used to render thumbnail pins for places that have user-added photos/videos.
    @EnvironmentObject private var mediaStore: PinMediaStore
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = true

    // Region is owned by the parent Map tab and passed in as a binding.
    @Binding var region: MKCoordinateRegion

    @State private var cameraPosition: MapCameraPosition

    @State private var pendingInitialRegion: MKCoordinateRegion?
    @State private var flightWorkItems: [DispatchWorkItem] = []

    // MARK: - Region safety
    /// MapKit will throw `Invalid Region` if the span is too large or contains NaN.
    /// When we show global radio stations, naive min/max longitude can produce a
    /// delta > 360 (or pick the long way around the dateline). This helper clamps
    /// and also computes the *shortest* longitude span around the globe.
    private static func safeRegion(for coords: [CLLocationCoordinate2D], minDelta: Double) -> MKCoordinateRegion {
        // Filter out invalid points.
        let pts = coords.filter {
            $0.latitude.isFinite && $0.longitude.isFinite &&
            $0.latitude >= -90 && $0.latitude <= 90
        }
        guard !pts.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.7897, longitude: -87.5997),
                span: MKCoordinateSpan(latitudeDelta: max(minDelta, 0.02), longitudeDelta: max(minDelta, 0.02))
            )
        }

        /// Normalizes a longitude value into the valid -180...180 range.
        func normalizeLon(_ lon: Double) -> Double {
            var x = lon.truncatingRemainder(dividingBy: 360)
            if x >= 180 { x -= 360 }
            if x < -180 { x += 360 }
            return x
        }

        // Latitude span is straightforward.
        let lats = pts.map { $0.latitude }
        let minLat = lats.min() ?? pts[0].latitude
        let maxLat = lats.max() ?? pts[0].latitude
        let centerLat = (minLat + maxLat) / 2

        // Longitude span: choose the shortest arc (handles dateline crossing).
        let sortedLons = pts.map { normalizeLon($0.longitude) }.sorted()
        let n = sortedLons.count

        var lonSpan: Double = 0
        var centerLon: Double = sortedLons[0]

        if n > 1 {
            var maxGap: Double = -1
            var gapIndex: Int = 0

            // Gaps between consecutive longitudes.
            for i in 0..<(n - 1) {
                let gap = sortedLons[i + 1] - sortedLons[i]
                if gap > maxGap {
                    maxGap = gap
                    gapIndex = i
                }
            }

            // Wrap-around gap (last -> first across +360).
            let wrapGap = (sortedLons[0] + 360) - sortedLons[n - 1]
            if wrapGap > maxGap {
                maxGap = wrapGap
                gapIndex = n - 1
            }

            lonSpan = max(0, 360 - maxGap)

            // The minimal interval starts right after the largest gap.
            let start = sortedLons[(gapIndex + 1) % n]
            let end = start + lonSpan
            centerLon = normalizeLon((start + end) / 2)
        }

        // Add padding but keep MapKit happy.
        let padding: Double = 1.25
        var latDelta = max(minDelta, (maxLat - minLat) * padding)
        var lonDelta = max(minDelta, lonSpan * padding)

        if !latDelta.isFinite || latDelta <= 0 { latDelta = minDelta }
        if !lonDelta.isFinite || lonDelta <= 0 { lonDelta = minDelta }

        // Hard clamps to avoid `Invalid Region`.
        latDelta = min(latDelta, 179.0)
        lonDelta = min(lonDelta, 359.0)

        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }

    init(
        places: [Place],
        stations: [RadioStation],
        activeSheet: Binding<PlacesMapTabView.ActiveSheet?>,
        region: Binding<MKCoordinateRegion>,
        flightRequest: Binding<RandomStationFlightRequest?>
    ) {
        self.places = places
        self.stations = stations
        self._activeSheet = activeSheet
        self._region = region
        self._flightRequest = flightRequest

        // If the parent gave us a wide "world" default, zoom to fit all annotations.
        let isWorldDefault =
            region.wrappedValue.span.latitudeDelta >= 79.0 &&
            region.wrappedValue.span.longitudeDelta >= 79.0

        if isWorldDefault {
            let coords: [CLLocationCoordinate2D] =
                (places.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }) +
                (stations.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) })

            let fitted = Self.safeRegion(for: coords, minDelta: 0.5)
            _pendingInitialRegion = State(initialValue: fitted)
            _cameraPosition = State(initialValue: .region(fitted))
        } else {
            _pendingInitialRegion = State(initialValue: nil)
            _cameraPosition = State(initialValue: .region(region.wrappedValue))
        }
    }

    /// Identifies whether a map annotation represents a place pin or a radio station.
    private enum AnnotationKind {
        case place(Place)
        case station(RadioStation)
    }

    /// Identifiable wrapper used to drive map annotations for places and stations.
    private struct AnnotationItem: Identifiable {
        let kind: AnnotationKind
        let coordinate: CLLocationCoordinate2D
        let title: String

        var id: String {
            switch kind {
            case .place(let p): return "place_" + p.id
            case .station(let s): return "station_" + s.id
            }
        }

        /// Text handed to MapKit for the system-managed annotation title.
        ///
        /// Station titles are intentionally suppressed here because MapKit can occasionally
        /// reuse or misplace those title layers while zooming, which causes duplicated or
        /// stray labels on the map. Accessibility still uses `title` on the tappable button.
        var systemAnnotationTitle: String {
            switch kind {
            case .place:
                return title
            case .station:
                return ""
            }
        }

        /// Keeps the visible marker anchored to the correct point on the map.
        ///
        /// - Places continue to use a bottom anchor so the pin tip sits on the coordinate.
        /// - Stations use a centered anchor because they render as a dot, not a pin with a tip.
        var anchor: UnitPoint {
            switch kind {
            case .place:
                return .bottom
            case .station:
                return .center
            }
        }

        /// Matches the content alignment to the anchor so enlarged tap targets do not visually
        /// offset the marker while zooming or panning the map.
        var contentAlignment: Alignment {
            switch kind {
            case .place:
                return .bottom
            case .station:
                return .center
            }
        }
    }

    private var items: [AnnotationItem] {
        let placeItems: [AnnotationItem] = places.map { p in
            AnnotationItem(
                kind: .place(p),
                coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                title: p.name
            )
        }
        let stationItems: [AnnotationItem] = stations.map { s in
            AnnotationItem(
                kind: .station(s),
                coordinate: CLLocationCoordinate2D(latitude: s.latitude, longitude: s.longitude),
                title: s.name
            )
        }
        return placeItems + stationItems
    }

    /// A token that changes whenever the user updates the media (photo/video) for a pin.
    /// Using it with `.id(...)` forces MapKit to refresh the annotation view immediately.
    private func mediaRefreshToken(for pinKey: String) -> String {
        mediaStore.changeToken(for: pinKey)
    }

    /// Compares two regions with a tolerance to avoid jittery region updates.
    private func regionsApproximatelyEqual(_ a: MKCoordinateRegion, _ b: MKCoordinateRegion) -> Bool {
        // Small epsilon to prevent feedback loops between camera updates and region binding.
        let eps = 0.000_001
        return abs(a.center.latitude - b.center.latitude) < eps &&
               abs(a.center.longitude - b.center.longitude) < eps &&
               abs(a.span.latitudeDelta - b.span.latitudeDelta) < eps &&
               abs(a.span.longitudeDelta - b.span.longitudeDelta) < eps
    }

    /// Normalized representation of a map region used to compare regions and avoid redundant updates.
    private struct RegionKey: Equatable {
        let centerLat: Double
        let centerLon: Double
        let latDelta: Double
        let lonDelta: Double

        init(_ r: MKCoordinateRegion) {
            // Round to reduce chatter from tiny camera updates.
            func round6(_ x: Double) -> Double { (x * 1_000_000).rounded() / 1_000_000 }
            centerLat = round6(r.center.latitude)
            centerLon = round6(r.center.longitude)
            latDelta  = round6(r.span.latitudeDelta)
            lonDelta  = round6(r.span.longitudeDelta)
        }
    }

    /// Presents a sheet reliably even if the user taps the same annotation twice in a row.
    private func presentSheet(_ sheet: PlacesMapTabView.ActiveSheet) {
        if activeSheet?.id == sheet.id {
            activeSheet = nil
            DispatchQueue.main.async {
                activeSheet = sheet
            }
        } else {
            activeSheet = sheet
        }
    }

    /// Opens the correct modal for a map annotation and logs the interaction.
    private func openAnnotation(_ item: AnnotationItem) {
        switch item.kind {
        case .place(let place):
            AppLog.action("Map pin tapped: place \(place.id) \(place.name)")
            AppLog.dump("Map place pin coordinate", [
                "lat": place.latitude,
                "lon": place.longitude
            ])
            presentSheet(.place(place))

        case .station(let station):
            AppLog.action("Map pin tapped: station \(station.id) \(station.name)")
            AppLog.dump("Map station pin coordinate", [
                "lat": station.latitude,
                "lon": station.longitude
            ])
            presentSheet(.station(station))
        }
    }

    /// Approximates a camera distance that fits the supplied region in view.
    private static func approximateCameraDistance(for region: MKCoordinateRegion) -> CLLocationDistance {
        let latitudeFactor = max(region.span.latitudeDelta, 0.02)
        let longitudeFactor = max(region.span.longitudeDelta, 0.02) * max(cos(region.center.latitude * .pi / 180), 0.2)
        let dominantDegrees = max(latitudeFactor, longitudeFactor)
        let meters = dominantDegrees * 111_000
        return min(max(meters * 2.1, 14_000), 18_000_000)
    }

    /// Returns the midpoint longitude while respecting the shortest wrap around the globe.
    private static func midpointLongitude(from start: Double, to end: Double) -> Double {
        interpolatedLongitude(from: start, to: end, progress: 0.5)
    }

    /// Interpolates longitudes across the shortest global arc so camera moves stay smooth near the dateline.
    private static func interpolatedLongitude(from start: Double, to end: Double, progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)

        var delta = end - start
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }

        var value = start + (delta * clamped)
        if value > 180 { value -= 360 }
        if value < -180 { value += 360 }
        return value
    }

    /// Shared interpolation helper used by the softened landing sequence.
    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + ((end - start) * min(max(progress, 0), 1))
    }

    /// A cubic ease-out curve so the camera decelerates smoothly near the destination.
    private static func easedLandingProgress(_ progress: Double) -> Double {
        let clamped = min(max(progress, 0), 1)
        return 1 - pow(1 - clamped, 3)
    }

    /// Interpolates between two regions, including wrapped longitude handling, for the final soft landing.
    private static func interpolatedRegion(from start: MKCoordinateRegion, to end: MKCoordinateRegion, progress: Double) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: interpolate(from: start.center.latitude, to: end.center.latitude, progress: progress),
                longitude: interpolatedLongitude(from: start.center.longitude, to: end.center.longitude, progress: progress)
            ),
            span: MKCoordinateSpan(
                latitudeDelta: interpolate(from: start.span.latitudeDelta, to: end.span.latitudeDelta, progress: progress),
                longitudeDelta: interpolate(from: start.span.longitudeDelta, to: end.span.longitudeDelta, progress: progress)
            )
        )
    }

    /// Computes a travel heading so the animated camera subtly leans into the direction of travel.
    private static func heading(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> CLLocationDirection {
        let startLat = start.latitude * .pi / 180
        let startLon = start.longitude * .pi / 180
        let endLat = end.latitude * .pi / 180
        let endLon = end.longitude * .pi / 180

        let y = sin(endLon - startLon) * cos(endLat)
        let x = cos(startLat) * sin(endLat) - sin(startLat) * cos(endLat) * cos(endLon - startLon)
        let radians = atan2(y, x)
        let degrees = radians * 180 / .pi
        return degrees >= 0 ? degrees : degrees + 360
    }

    /// Cancels any in-flight delayed camera steps before starting a new sequence.
    private func cancelFlightWorkItems() {
        flightWorkItems.forEach { $0.cancel() }
        flightWorkItems.removeAll()
    }

    /// Queues a map camera step on the main queue so the movement feels like a guided flyover.
    private func queueFlightStep(after delay: TimeInterval, _ action: @escaping () -> Void) {
        let workItem = DispatchWorkItem(block: action)
        flightWorkItems.append(workItem)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// Animates the SwiftUI map camera to a region with optional pitch + heading for a more cinematic feel.
    private func animateCamera(to targetRegion: MKCoordinateRegion, heading: CLLocationDirection, pitch: Double, duration: Double) {
        let distance = Self.approximateCameraDistance(for: targetRegion)
        withAnimation(.easeInOut(duration: duration)) {
            cameraPosition = .camera(
                MapCamera(
                    centerCoordinate: targetRegion.center,
                    distance: distance,
                    heading: heading,
                    pitch: pitch
                )
            )
        }
    }

    /// Adds smaller overlapping camera steps near the destination so the landing feels more continuous.
    @discardableResult
    // Queues soft landing for this feature.
    private func queueSoftLanding(from startRegion: MKCoordinateRegion,
                                  to endRegion: MKCoordinateRegion,
                                  heading: CLLocationDirection,
                                  startDelay: TimeInterval) -> TimeInterval {
        let stepCount = 6
        let stepInterval: TimeInterval = 0.11
        let stepDuration: Double = 0.17

        AppLog.info("Random station flyover entering soft landing with \(stepCount) easing steps")

        for step in 1...stepCount {
            let rawProgress = Double(step) / Double(stepCount)
            let progress = Self.easedLandingProgress(rawProgress)
            let intermediateRegion = Self.interpolatedRegion(from: startRegion, to: endRegion, progress: progress)
            let intermediatePitch = Self.interpolate(from: 26, to: 8, progress: progress)
            let delay = startDelay + (Double(step - 1) * stepInterval)

            queueFlightStep(after: delay) {
                animateCamera(to: intermediateRegion, heading: heading, pitch: intermediatePitch, duration: stepDuration)
            }
        }

        return startDelay + (Double(stepCount - 1) * stepInterval) + stepDuration
    }

    /// Performs the staged random-station flyover while respecting Reduce Motion.
    private func performRandomStationFlight(_ request: RandomStationFlightRequest) {
        cancelFlightWorkItems()

        if accessibilityReduceMotion {
            AppLog.info("Reduce Motion enabled; random station flyover collapsed to a direct jump")
            withAnimation(.easeInOut(duration: 0.2)) {
                cameraPosition = .region(request.finalRegion)
            }
            region = request.finalRegion
            flightRequest = nil
            return
        }

        let heading = Self.heading(from: request.startCoordinate, to: request.targetCoordinate)
        let launchRegion = MKCoordinateRegion(
            center: request.startCoordinate,
            span: request.overviewRegion.span
        )
        let cruiseOneRegion = Self.interpolatedRegion(
            from: launchRegion,
            to: request.finalRegion,
            progress: 0.24
        )
        let cruiseTwoRegion = Self.interpolatedRegion(
            from: launchRegion,
            to: request.finalRegion,
            progress: 0.52
        )
        let approachRegion = Self.interpolatedRegion(
            from: launchRegion,
            to: request.finalRegion,
            progress: 0.82
        )

        AppLog.info("Running random station flyover animation with continuous zoom-in and a softened landing")

        animateCamera(to: launchRegion, heading: heading, pitch: 46, duration: 0.24)

        queueFlightStep(after: 0.16) {
            animateCamera(to: cruiseOneRegion, heading: heading, pitch: 58, duration: 0.44)
        }

        queueFlightStep(after: 0.52) {
            animateCamera(to: cruiseTwoRegion, heading: heading, pitch: 46, duration: 0.48)
        }

        queueFlightStep(after: 0.94) {
            AppLog.info("Random station flyover entering continuous zoomed approach")
            animateCamera(to: approachRegion, heading: heading, pitch: 24, duration: 0.46)
        }

        let landingEnd = queueSoftLanding(
            from: approachRegion,
            to: request.finalRegion,
            heading: heading,
            startDelay: 1.28
        )

        queueFlightStep(after: landingEnd + 0.04) {
            region = request.finalRegion
            flightRequest = nil
        }
    }

    var body: some View {
        Map(position: $cameraPosition) {
            // Replaces the older `showsUserLocation:` parameter.
            UserAnnotation()

            ForEach(items) { item in
                Annotation(item.systemAnnotationTitle, coordinate: item.coordinate, anchor: item.anchor) {
                    Button {
                        openAnnotation(item)
                    } label: {
                        ZStack(alignment: item.contentAlignment) {
                            // Keep the visual marker the same, but enlarge the tappable target so
                            // taps are reliably recognized instead of being interpreted as map pans.
                            Circle()
                                .fill(Color.clear)
                                .frame(width: 44, height: 44)

                            Group {
                                switch item.kind {
                                case .place:
                                    if let ui = mediaStore.firstThumbnail(for: item.id) {
                                        Image(uiImage: ui)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 34, height: 34)
                                            .clipShape(Circle())
                                            .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                            .shadow(radius: 2)
                                    } else {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.title2)
                                            .foregroundColor(.red)
                                            .shadow(radius: 2)
                                    }

                                case .station:
                                    // Stations still look like a small red dot, but now sit inside
                                    // a larger invisible tap target for reliability.
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 10, height: 10)
                                        .shadow(radius: 1)
                                }
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .id(mediaRefreshToken(for: item.id))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(item.title)
                        .accessibilityHint("Opens details")
                        .accessibilityAddTraits(.isButton)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .mapStyle(mapIsSatellite ? .imagery : .standard)
        .task {
            guard let r = pendingInitialRegion else { return }
            pendingInitialRegion = nil
            // Defer updating the parent binding until after the first render to avoid
            // \"Modifying state during view update\" warnings.
            await MainActor.run {
                region = r
                cameraPosition = .region(r)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            // Keep the parent's region binding in sync (used by search / UI).
            region = context.region
        }
        .onChange(of: RegionKey(region)) { _, _ in
            // If something external updates the region (e.g. search result jump),
            // reflect it in the camera position.
            let newRegion = region
            cameraPosition = .region(newRegion)
        }
        .onChange(of: flightRequest?.id) { _, _ in
            guard let request = flightRequest else { return }
            performRandomStationFlight(request)
        }
        .onDisappear {
            cancelFlightWorkItems()
            flightRequest = nil
        }
    }
}



/// Map view used on the Places tab to show places and stations in context.
struct PlacesOverviewMapView: View {
    let places: [Place]
    @Binding var modalPlace: Place?

    // Used to render thumbnail pins for places that have user-added photos/videos.
    @EnvironmentObject private var mediaStore: PinMediaStore

    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = true

    @State private var cameraPosition: MapCameraPosition

    init(places: [Place], modalPlace: Binding<Place?>) {
        self.places = places
        self._modalPlace = modalPlace
        let initial = Self.initialRegion(for: places)
        _cameraPosition = State(initialValue: .region(initial))
    }

    /// Produces a token that forces media subviews to refresh when the attachment list changes.
    private func mediaRefreshToken(for pinKey: String) -> String {
        mediaStore.changeToken(for: pinKey)
    }

    var body: some View {
        Map(position: $cameraPosition) {
            ForEach(places) { p in
                Annotation(p.name, coordinate: p.coordinate, anchor: .bottom) {
                    Button {
                        modalPlace = p
                    } label: {
                        if let ui = mediaStore.firstThumbnail(for: "place_" + p.id) {
                            Image(uiImage: ui)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 30, height: 30)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                                .shadow(radius: 2)
                        } else {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title3)
                                .shadow(radius: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open place card")
                    .id(mediaRefreshToken(for: "place_" + p.id))
                }
            }
        }
        .mapStyle(mapIsSatellite ? .imagery : .standard)
        .frame(minHeight: 320)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }

    /// Performs initial region.
    private static func initialRegion(for places: [Place]) -> MKCoordinateRegion {
        guard !places.isEmpty else {
            return MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: 41.7921, longitude: -87.5994),
                span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
            )
        }

        let lats = places.map { $0.latitude }
        let lons = places.map { $0.longitude }
        let minLat = lats.min() ?? places[0].latitude
        let maxLat = lats.max() ?? places[0].latitude
        let minLon = lons.min() ?? places[0].longitude
        let maxLon = lons.max() ?? places[0].longitude

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Add a little padding so pins aren't glued to the edges.
        // Also clamp to keep MapKit from throwing `Invalid Region` for extreme spans.
        var latDelta = max(0.02, (maxLat - minLat) * 1.6)
        var lonDelta = max(0.02, (maxLon - minLon) * 1.6)
        if !latDelta.isFinite || latDelta <= 0 { latDelta = 0.04 }
        if !lonDelta.isFinite || lonDelta <= 0 { lonDelta = 0.04 }
        latDelta = min(latDelta, 179.0)
        lonDelta = min(lonDelta, 359.0)

        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )
    }
}

/// Placeholder detail view shown when no selection is active (useful for larger screens).
struct DefaultDetailView: View {
    let places: [Place]

    @State private var modalPlace: Place? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select a place")
                .font(.title3).bold()
            Text("Choose an item from the list to see details, or use the map below to preview all locations.")
                .foregroundColor(.secondary)
                .font(.subheadline)

            if places.isEmpty {
                EmptyStateView(
                    title: "No places loaded",
                    systemImage: "exclamationmark.triangle",
                    message: "The bundled places.json couldn't be read. Make sure Resources/places.json exists in the project."
                )
            } else {
                PlacesOverviewMapView(places: places, modalPlace: $modalPlace)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .navigationTitle("Overview")
        .sheet(item: $modalPlace) { p in
            PlaceMusicModalView(place: p)
        }
    }
}

/// Detail view for a place that shows metadata, media, and playback controls.
struct PlaceDetailView: View {
    let place: Place
    let places: [Place]
    @Binding var favorites: Set<String>

    @State private var startID: String = ""
    @State private var modalPlace: Place? = nil
    @State private var selectedCategory: PlaceCategory
    @State private var showingCategoryPicker: Bool = false

    init(place: Place, places: [Place], favorites: Binding<Set<String>>) {
        self.place = place
        self.places = places
        self._favorites = favorites
        self._selectedCategory = State(initialValue: place.effectiveCategory)
    }

    private var startPlace: Place? {
        places.first(where: { $0.id == startID }) ?? places.first
    }

    private var distanceMeters: Double? {
        guard let startPlace else { return nil }
        return Geo.haversineMeters(lat1: startPlace.latitude, lon1: startPlace.longitude, lat2: place.latitude, lon2: place.longitude)
    }

    private var isFavorite: Bool { favorites.contains(place.id) }

    // Synchronizes selected category from store for this feature.
    private func syncSelectedCategoryFromStore() {
        let resolvedCategory = PlaceCategoryOverrideStore.category(for: place)
        if selectedCategory != resolvedCategory {
            selectedCategory = resolvedCategory
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(place.name)
                            .font(.title2).bold()
                        Text(place.subtitle)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button {
                        toggleFavorite(place.id)
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title2)
                            .foregroundStyle(isFavorite ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                }

                // Add an offline map preview with a pin...
                PlaceMapView(place: place, modalPlace: $modalPlace)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Category")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button {
                        AppLog.action("Open place category picker: \(place.id)")
                        showingCategoryPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedCategory.systemImageName)
                                .foregroundStyle(.secondary)
                            Text(selectedCategory.displayName)
                                .font(.body)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .transaction { transaction in
                            transaction.animation = nil
                        }
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog(
                        "Choose Category",
                        isPresented: $showingCategoryPicker,
                        titleVisibility: .visible
                    ) {
                        ForEach(PlaceCategory.allCases) { category in
                            Button(category == selectedCategory ? "✓ \(category.displayName)" : category.displayName) {
                                selectedCategory = category
                            }
                        }
                        Button("Cancel", role: .cancel) { }
                    } message: {
                        Text("Choose a category for this place.")
                    }
                    .accessibilityLabel("Category")
                    .accessibilityValue(selectedCategory.displayName)
                    .accessibilityHint("Choose a category for this place.")
                    .accessibilityAddTraits(.isButton)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                InfoCard(title: "Hours", value: place.hours)
                InfoCard(title: "Address", value: place.address)
                if !place.notes.isEmpty {
                    InfoCard(title: "Notes", value: place.notes)
                }

                Divider().padding(.vertical, 6)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Offline directions")
                        .font(.headline)

                    Text("Pick a starting point and get quick walking directions. This demo stays offline—no network needed.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Start", selection: $startID) {
                        ForEach(places.sorted(by: { $0.name < $1.name })) { p in
                            Text(p.name).tag(p.id)
                        }
                    }
                    .pickerStyle(.menu)

                    if let startPlace, startPlace.id != place.id, let meters = distanceMeters {
                        DirectionsCard(start: startPlace, end: place, meters: meters)
                    } else if let startPlace, startPlace.id == place.id {
                        EmptyStateView(
                            title: "You're already here",
                            systemImage: "figure.walk",
                            message: "Choose a different starting point."
                        )
                            .padding(.top, 6)
                    } else {
                        EmptyStateView(
                            title: "Pick a start",
                            systemImage: "location.circle",
                            message: "Select a starting point to see directions."
                        )
                            .padding(.top, 6)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedCategory) { oldValue, newValue in
            guard oldValue != newValue else { return }
            PlaceCategoryOverrideStore.set(newValue, for: place)
        }
        .sheet(item: $modalPlace) { p in
            PlaceMusicModalView(place: p)
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaceCategoryOverrideStore.didChangeNotification)) { notification in
            guard let payload = PlaceCategoryOverrideStore.changePayload(from: notification),
                  payload.placeID == place.id else { return }
            if selectedCategory != payload.category {
                selectedCategory = payload.category
            }
        }
        .onAppear {
            syncSelectedCategoryFromStore()
            if startID.isEmpty {
                startID = places.first?.id ?? ""
            }
        }
    }

    /// Toggles the favorite state for an item and persists the change.
    private func toggleFavorite(_ id: String) {
        let willFavorite = !favorites.contains(id)
        AppLog.action("Favorite \(willFavorite ? "ADD" : "REMOVE"): \(id)")
        if willFavorite {
            favorites.insert(id)
        } else {
            favorites.remove(id)
        }
    }
}

/// Reusable card presenting a directions action for a place.
struct DirectionsCard: View {
    let start: Place
    let end: Place
    let meters: Double

    var body: some View {
        let minutes = Geo.walkingMinutes(for: meters)
        let dir = Geo.cardinalDirection(fromLat: start.latitude, fromLon: start.longitude, toLat: end.latitude, toLon: end.longitude)
        let prettyDistance = meters >= 1000 ? String(format: "%.2f km", meters / 1000.0) : String(format: "%.0f m", meters)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "figure.walk")
                Text("\(prettyDistance) · ~\(minutes) min")
                    .font(.subheadline).bold()
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("1) Leave **\(start.name)** and head **\(dir)**.")
                Text("2) Keep going until you reach **\(end.name)**.")
                Text("3) Look for: \(end.subtitle).")
            }
            .font(.subheadline)

            HStack(spacing: 10) {
                Badge(text: start.effectiveCategory.displayName)
                Badge(text: end.effectiveCategory.displayName)
                Spacer()
            }
        }
        .padding(14)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Reusable container card used throughout the UI for grouped content.
struct InfoCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundColor(.secondary)
            Text(value).font(.body)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Small badge view used to highlight short bits of metadata.
struct Badge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
    }
}

/// Pill-shaped chip used for compact actions or status indicators.
struct Chip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                // Use Color.* instead of ShapeStyle.* to avoid older compiler issues.
                .background(isSelected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.10))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// About screen describing the app and the required project information.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image("AppLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                Text("Campus Navigator Lite")
                    .font(.title2).bold()

                Text("A tiny offline demo: search places, favorite them, preview locations on a map, and generate quick walking directions. No network required.")
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Try this flow")
                        .font(.headline)
                    Text("1) Use Search to find a place (try “coffee” or “library”).")
                    Text("2) Tap the ⭐ to favorite it.")
                    Text("3) Switch the top picker to Favorites.")
                    Text("4) Open a place and choose a Start to see directions.")
                }
                .font(.subheadline)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Why it fits the assignment")
                        .font(.headline)
                    Text("• Interactive and understandable in under 3 minutes.")
                    Text("• Works offline: all data is bundled locally.")
                    Text("• Shows core iOS UI patterns: Navigation, Search, Filters, Persistence.")
                }
                .font(.subheadline)
            }
            .padding(16)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - User-added photos per pin

/// Reusable section used in pin modal cards to let the user attach photos
/// from their photo library, and display the saved images.
struct PinPhotoSection: View {
    let title: String
    let pinKey: String

    @EnvironmentObject private var photoStore: PinPhotoStore
    @State private var pickedItems: [PhotosPickerItem] = []

    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage? = nil
    @State private var showNoCameraAlert = false

    private var files: [String] {
        photoStore.filenames(for: pinKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()

if #available(iOS 16.0, *) {
                    HStack(spacing: 12) {
                        PhotosPicker(
                            selection: $pickedItems,
                            maxSelectionCount: 10,
                            matching: .images,
                            photoLibrary: .shared()
                        ) {
                            Label("Add", systemImage: "photo.on.rectangle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                isShowingCamera = true
                            } else {
                                showNoCameraAlert = true
                            }
                        } label: {
                            Label("Take a photo", systemImage: "camera")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Text("Requires iOS 16+")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if files.isEmpty {
                Text("No photos yet. Tap Add to choose from your library.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(files, id: \.self) { filename in
                            if let img = photoStore.image(for: filename) {
                                ZStack(alignment: .topTrailing) {
                                    Image(uiImage: img)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 120, height: 90)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                    Button(role: .destructive) {
                                        photoStore.removeImage(filename: filename, from: pinKey)
                                    } label: {
                                        Image(systemName: "trash.circle.fill")
                                            .font(.title3)
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .red)
                                            .padding(4)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Delete photo")
                                }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $isShowingCamera, onDismiss: {
            guard let img = capturedImage, let data = img.jpegData(compressionQuality: 0.85) else { return }
            photoStore.addImageData(data, to: pinKey)
            capturedImage = nil
        }) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .alert("Camera Not Available", isPresented: $showNoCameraAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This device doesn't have a camera, or camera access is restricted.")
        }
        .onChange(of: pickedItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            photoStore.addImageData(data, to: pinKey)
                        }
                    }
                }
                await MainActor.run {
                    pickedItems = []
                }
            }
        }
    }
}

// MARK: - User-added media per place pin (photos + videos)

@available(iOS 16.0, *)
/// Value type that tracks a selected or recorded video and its local file URL.
struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { video in
            SentTransferredFile(video.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            // Copy into a stable temp URL we own.
            AppLog.action("Import video")
            AppLog.fileOp("READ", received.file)
            AppLog.fileOp("WRITE", temp)
            try FileManager.default.copyItem(at: received.file, to: temp)
            return PickedVideo(url: temp)
        }
    }
}

/// UI section for adding, viewing, and deleting photo/video media attachments on a place pin.
struct PinMediaSection: View {
    let title: String
    let pinKey: String

    @EnvironmentObject private var mediaStore: PinMediaStore

    @State private var pickedPhotoItems: [PhotosPickerItem] = []
    @State private var pickedVideoItems: [PhotosPickerItem] = []

    @State private var showAddMediaDialog = false
    @State private var showTakeNewDialog = false
    @State private var showPhotoLibraryPicker = false
    @State private var showVideoLibraryPicker = false

    @State private var isShowingPhotoCamera = false
    @State private var capturedImage: UIImage? = nil

    @State private var isShowingVideoCamera = false
    @State private var capturedVideoURL: URL? = nil

    @State private var showNoCameraAlert = false

    @State private var activeVideoItem: PinMediaItem? = nil
    @State private var activeVideoPlayer: AVPlayer? = nil

    private var items: [PinMediaItem] {
        mediaStore.items(for: pinKey)
    }

    /// Performs stop video.
    private func stopVideo() {
        activeVideoPlayer?.pause()
        activeVideoPlayer = nil
        activeVideoItem = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()

                if #available(iOS 16.0, *) {
                    HStack(spacing: 12) {
                        Button {
                            showAddMediaDialog = true
                        } label: {
                            Label("Add media", systemImage: "photo.on.rectangle")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .confirmationDialog("Add media", isPresented: $showAddMediaDialog, titleVisibility: .visible) {
                            Button("Choose photo") { showPhotoLibraryPicker = true }
                            Button("Choose video") { showVideoLibraryPicker = true }
                            Button("Cancel", role: .cancel) { }
                        }
                        .photosPicker(
                            isPresented: $showPhotoLibraryPicker,
                            selection: $pickedPhotoItems,
                            maxSelectionCount: 10,
                            matching: .images,
                            photoLibrary: .shared()
                        )
                        .photosPicker(
                            isPresented: $showVideoLibraryPicker,
                            selection: $pickedVideoItems,
                            maxSelectionCount: 3,
                            matching: .videos,
                            photoLibrary: .shared()
                        )

                        Button {
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                showTakeNewDialog = true
                            } else {
                                showNoCameraAlert = true
                            }
                        } label: {
                            Label("Take new", systemImage: "camera")
                                .font(.subheadline)
                        }
                        .buttonStyle(.borderless)
                        .confirmationDialog("Take new", isPresented: $showTakeNewDialog, titleVisibility: .visible) {
                            Button("Take photo") { isShowingPhotoCamera = true }
                            Button("Record video") { isShowingVideoCamera = true }
                            Button("Cancel", role: .cancel) { }
                        }
                    }
                } else {
                    Text("Requires iOS 16+")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if items.isEmpty {
                Text("No media yet. Add a photo or video.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(items) { item in
                            let isVideo = item.kind == .video
                            ZStack(alignment: .topTrailing) {
                                if isVideo {
                                    Button {
                                        activeVideoItem = item
                                    } label: {
                                    ZStack {
                                        if let thumb = mediaStore.thumbnail(for: item) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            Rectangle()
                                                .fill(Color.secondary.opacity(0.15))
                                                .overlay(
                                                    Image(systemName: isVideo ? "video" : "photo")
                                                        .font(.title3)
                                                        .foregroundColor(.secondary)
                                                )
                                        }

                                        if isVideo {
                                            Image(systemName: "play.circle.fill")
                                                .font(.title)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.25))
                                        }
                                    }
                                    .frame(width: 120, height: 90)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Play video")
                                    .accessibilityHint("Opens video player")
                                } else {
                                    ZStack {
                                        if let thumb = mediaStore.thumbnail(for: item) {
                                            Image(uiImage: thumb)
                                                .resizable()
                                                .scaledToFill()
                                        } else {
                                            Rectangle()
                                                .fill(Color.secondary.opacity(0.15))
                                                .overlay(
                                                    Image(systemName: isVideo ? "video" : "photo")
                                                        .font(.title3)
                                                        .foregroundColor(.secondary)
                                                )
                                        }

                                        if isVideo {
                                            Image(systemName: "play.circle.fill")
                                                .font(.title)
                                                .symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.25))
                                        }
                                    }
                                    .frame(width: 120, height: 90)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityLabel("Photo attachment")
                                }

                                Button(role: .destructive) {
                                    if activeVideoItem?.id == item.id {
                                        stopVideo()
                                    }
                                    mediaStore.remove(itemID: item.id, from: pinKey)
                                } label: {
                                    Image(systemName: "trash.circle.fill")
                                        .font(.title3)
                                        .symbolRenderingMode(.palette)
                                        .foregroundStyle(.white, .red)
                                        .padding(4)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(isVideo ? "Delete video" : "Delete photo")
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            if let item = activeVideoItem,
               let url = mediaStore.videoURL(for: item) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "video")
                        Text("Video")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Spacer()
                        Button {
                            stopVideo()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close video")
                    }

                    Group {
                        if let player = activeVideoPlayer {
                            CrispInlineVideoPlayer(player: player)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .onAppear {
                        // Build or refresh the player.
                        if activeVideoPlayer == nil {
                            let p = AVPlayer(url: url)
                            activeVideoPlayer = p
                            p.play()
                        }
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sheet(isPresented: $isShowingPhotoCamera, onDismiss: {
            guard let img = capturedImage, let data = img.jpegData(compressionQuality: 0.85) else { return }
            mediaStore.addPhotoData(data, to: pinKey)
            capturedImage = nil
        }) {
            CameraPicker(image: $capturedImage)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isShowingVideoCamera, onDismiss: {
            guard let url = capturedVideoURL else { return }
            mediaStore.addVideoFile(at: url, to: pinKey)
            capturedVideoURL = nil
        }) {
            VideoCapturePicker(videoURL: $capturedVideoURL)
                .ignoresSafeArea()
        }
        .alert("Camera Not Available", isPresented: $showNoCameraAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("This device doesn't have a camera, or camera access is restricted.")
        }
        .onChange(of: pickedPhotoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run {
                            mediaStore.addPhotoData(data, to: pinKey)
                        }
                    }
                }
                await MainActor.run {
                    pickedPhotoItems = []
                }
            }
        }
        .onChange(of: pickedVideoItems) { _, newItems in
            guard !newItems.isEmpty else { return }
            Task {
                for item in newItems {
                    if #available(iOS 16.0, *),
                       let picked = try? await item.loadTransferable(type: PickedVideo.self) {
                        await MainActor.run {
                            mediaStore.addVideoFile(at: picked.url, to: pinKey)
                        }
                    }
                }
                await MainActor.run {
                    pickedVideoItems = []
                }
            }
        }
        .onChange(of: activeVideoItem?.id) { _, _ in
            // Rebuild player when the selected video changes.
            guard let item = activeVideoItem,
                  let url = mediaStore.videoURL(for: item) else {
                activeVideoPlayer?.pause()
                activeVideoPlayer = nil
                return
            }
            activeVideoPlayer?.pause()
            let p = AVPlayer(url: url)
            activeVideoPlayer = p
            p.play()
        }
        .onDisappear {
            activeVideoPlayer?.pause()
        }
    }
}

/// UIKit camera capture wrapper used by `PinPhotoSection`.
///
/// We use `UIImagePickerController` for broad compatibility.
struct CameraPicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?

    // Coordinator coordinates custom state and behavior for this feature area.
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) {
            self.parent = parent
        }

        /// Performs image picker controller.
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let ui = info[.originalImage] as? UIImage {
                parent.image = ui
            }
            picker.dismiss(animated: true)
        }

        /// Performs image picker controller did cancel.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }

    /// Creates the coordinator object used to bridge UIKit delegate callbacks.
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Creates and returns the UIKit view controller used by this representable.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    /// Updates the wrapped view controller when SwiftUI state changes.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) { }
}

/// UIKit video capture wrapper used by `PinMediaSection`.
struct VideoCapturePicker: UIViewControllerRepresentable {
    @Binding var videoURL: URL?

    /// Creates and returns the UIKit view controller used by this representable.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = [UTType.movie.identifier]
        picker.cameraCaptureMode = .video
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    /// Updates the wrapped view controller when SwiftUI state changes.
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    /// Creates the coordinator object used to bridge UIKit delegate callbacks.
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // Coordinator coordinates custom state and behavior for this feature area.
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: VideoCapturePicker
        init(_ parent: VideoCapturePicker) { self.parent = parent }

        /// Performs image picker controller.
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let url = info[.mediaURL] as? URL {
                parent.videoURL = url
            }
            picker.dismiss(animated: true)
        }

        /// Performs image picker controller did cancel.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}



// MARK: - Crisp inline video playback (avoids blurry system controls)

/// A UIView backed by `AVPlayerLayer`.
private final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }
}

/// SwiftUI wrapper for `PlayerLayerView`.
private struct PlayerLayerRepresentable: UIViewRepresentable {
    let player: AVPlayer

    /// Creates and returns the UIKit view used by this representable.
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.player = player
        return v
    }

    /// Updates the wrapped UIKit view when SwiftUI state changes.
    func updateUIView(_ uiView: PlayerLayerView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

/// View model that synchronizes AVPlayer time with custom playback controls.
private final class VideoPlaybackViewModel: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying: Bool = false

    private weak var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var timeControlObserver: NSKeyValueObservation?
    private var currentItemObserver: NSKeyValueObservation?
    private var itemStatusObserver: NSKeyValueObservation?

    /// Attaches observers to the provided player and begins publishing playback state.
    func attach(to player: AVPlayer) {
        detach()

        self.player = player
        refreshFromPlayer(player)
        bind(to: player.currentItem)

        timeControlObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.refreshFromPlayer(player)
            }
        }

        currentItemObserver = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                self?.bind(to: player.currentItem)
                self?.refreshFromPlayer(player)
            }
        }

        // A slightly tighter interval keeps the scrubber in sync with playback.
        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            if seconds.isFinite {
                let cap = self.duration > 0 ? self.duration : seconds
                self.currentTime = max(0, min(seconds, cap))
            }

            if let item = player.currentItem {
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.duration = d
                }
            }

            self.isPlaying = (player.timeControlStatus == .playing) || player.rate > 0
        }
    }

    // Binds the requested action for this feature.
    private func bind(to item: AVPlayerItem?) {
        itemStatusObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        guard let item else {
            duration = 0
            currentTime = 0
            return
        }

        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let d = item.duration.seconds
                if d.isFinite, d > 0 {
                    self.duration = d
                }
                if item.status == .failed {
                    AppLog.info("Inline video item failed: \(item.error?.localizedDescription ?? "unknown error")")
                }
                if let player = self.player {
                    self.refreshFromPlayer(player)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.currentTime = self.duration
            self.isPlaying = false
            AppLog.info("Inline video reached end")
        }
    }

    // Refreshes from player for this feature.
    private func refreshFromPlayer(_ player: AVPlayer) {
        let now = player.currentTime().seconds
        if now.isFinite {
            let cap = duration > 0 ? duration : now
            currentTime = max(0, min(now, cap))
        }

        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 {
                duration = d
            }
        }

        isPlaying = (player.timeControlStatus == .playing) || player.rate > 0
    }

    /// Stops observing the player and releases any observers or notifications.
    func detach() {
        if let player = player, let token = timeObserver {
            player.removeTimeObserver(token)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil

        timeControlObserver = nil
        currentItemObserver = nil
        itemStatusObserver = nil
        player = nil
    }

    /// Toggles between play and pause for the current media.
    func togglePlayPause() {
        guard let player else { return }
        if player.timeControlStatus == .playing || player.rate > 0 {
            AppLog.action("Pause inline video")
            player.pause()
            isPlaying = false
        } else {
            let isAtEnd = duration > 0 && currentTime >= max(duration - 0.05, 0)
            if isAtEnd {
                AppLog.action("Restart inline video from beginning")
                seek(to: 0)
            } else {
                AppLog.action("Play inline video")
            }
            player.play()
            isPlaying = true
        }
    }

    /// Seeks the player to a new time and keeps UI state in sync.
    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        let t = CMTime(seconds: clamped, preferredTimescale: 600)
        AppLog.info("Inline video seek to \(String(format: "%.2f", clamped))s")
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard let self else { return }
            if finished {
                // Immediately reflect the seek target so the UI stays aligned
                // even before the next time observer tick.
                self.currentTime = clamped
                self.isPlaying = (player.timeControlStatus == .playing) || player.rate > 0
            }
        }
    }
}

/// Formats a time interval in seconds as mm:ss for display.
private func _formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds.rounded(.down))
    let m = s / 60
    let r = s % 60
    return String(format: "%d:%02d", m, r)
}

/// Inline video view with crisp SwiftUI controls (no blurry system overlay).
private struct CrispInlineVideoPlayer: View {
    let player: AVPlayer

    @StateObject private var vm = VideoPlaybackViewModel()

    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var wasPlayingBeforeScrub = false
    @State private var pendingSeekWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack(alignment: .bottom) {
            PlayerLayerRepresentable(player: player)

            VStack(spacing: 8) {
                // Progress
                Slider(
                    value: Binding(
                        get: { isScrubbing ? scrubValue : vm.currentTime },
                        set: { newValue in
                            scrubValue = newValue
                        }
                    ),
                    in: 0...(vm.duration > 0 ? vm.duration : 1),
                    onEditingChanged: { editing in
                        if editing {
                            // Start scrubbing: pause playback and keep UI driven by the slider.
                            wasPlayingBeforeScrub = vm.isPlaying
                            if wasPlayingBeforeScrub {
                                player.pause()
                                vm.isPlaying = false
                            }
                            scrubValue = vm.currentTime
                            isScrubbing = true
                        } else {
                            // Finish scrubbing: perform an exact seek, then resume if needed.
                            pendingSeekWorkItem?.cancel()
                            pendingSeekWorkItem = nil
                            let target = scrubValue
                            // Keep `isScrubbing` true until the seek target is reflected.
                            vm.seek(to: target)
                            DispatchQueue.main.async {
                                isScrubbing = false
                                if wasPlayingBeforeScrub {
                                    player.play()
                                    vm.isPlaying = true
                                }
                            }
                        }
                    }
                )
                .tint(.white)
                .disabled(vm.duration <= 0)
                .accessibilityLabel("Video position")
                .accessibilityValue("\(_formatTime(isScrubbing ? scrubValue : vm.currentTime)) of \(_formatTime(vm.duration))")
                .accessibilityHint("Shows and adjusts the current playback position")

                HStack(spacing: 12) {
                    Button {
                        vm.togglePlayPause()
                    } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.14)))
                    }
                    .buttonStyle(.plain)
                    .contentShape(Circle())
                    .accessibilityLabel(vm.isPlaying ? "Pause video" : "Play video")
                    .accessibilityHint("Toggles video playback")

                    Text(_formatTime(isScrubbing ? scrubValue : vm.currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white.opacity(0.92))

                    Spacer()

                    if vm.duration > 0 {
                        Text(_formatTime(vm.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundColor(.white.opacity(0.72))
                    }
                }
            }
            .padding(10)
            // Use a simple translucent overlay (no blur) to keep controls crisp.
            .background(Color.black.opacity(0.35))
        }
        .onAppear { vm.attach(to: player) }
        .onDisappear {
            pendingSeekWorkItem?.cancel()
            pendingSeekWorkItem = nil
            vm.detach()
        }
        .onChange(of: scrubValue) { _, newValue in
            // While scrubbing, keep the displayed frame in sync with the scrubber.
            guard isScrubbing else { return }
            pendingSeekWorkItem?.cancel()
            let target = newValue
            let work = DispatchWorkItem { vm.seek(to: target) }
            pendingSeekWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }
}


/// Bottom-sheet card for a place pin, including media, built-in sounds, and pin actions.
struct PlaceMusicModalView: View {
    let place: Place
    @Binding var favorites: Set<String>
    @Binding var detent: PresentationDetent

    /// Optional: when provided, shows a destructive "Delete pin" button.
    /// The caller should remove the pin from its backing array (e.g. places.removeAll { ... }).
    let onDelete: (() -> Void)?

    @ObservedObject private var audio = AudioManager.shared
    @EnvironmentObject private var recents: RecentManager
    @EnvironmentObject private var photoStore: PinPhotoStore
    @EnvironmentObject private var mediaStore: PinMediaStore
    @EnvironmentObject private var pinAudioStore: PinAudioSelectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var showSoundPicker = false
    @State private var showDeleteConfirm = false
    // No explicit close button: the sheet is dismissed by pulling down or tapping outside.

    init(
        place: Place,
        favorites: Binding<Set<String>> = .constant([]),
        detent: Binding<PresentationDetent> = .constant(.height(360)),
        onDelete: (() -> Void)? = nil
    ) {
        self.place = place
        self._favorites = favorites
        self._detent = detent
        self.onDelete = onDelete
    }

    private var pinKey: String { "place_" + place.id }

    private var selectedSoundBaseName: String? {
        pinAudioStore.selection(for: pinKey)
    }
    private var track: String { selectedSoundBaseName ?? place.audioTrackBaseName }
    private var trackTitle: String {
        if let base = selectedSoundBaseName {
            return BuiltInSoundLibrary.title(for: base)
        }
        return place.audioTrackTitle
    }
    private var isFavorite: Bool { favorites.contains(place.id) }

    private let compactDetent: PresentationDetent = .height(360)
    private var isCompact: Bool { detent == compactDetent }

    private var hasMedia: Bool {
        !mediaStore.items(for: pinKey).isEmpty
    }

    private var headerTopPadding: CGFloat {
        // In the compact detent, content can get visually clipped under the grabber when the
        // view becomes taller (e.g. after the user adds photos). Padding never compresses
        // away like a spacer, so it keeps the header safely inside the card.
        if isCompact {
            return hasMedia ? 32 : 20
        }
        return 12
    }

    /// Toggles the favorite state for an item and persists the change.
    private func toggleFavorite() {
        let willFavorite = !isFavorite
        AppLog.action("Favorite \(willFavorite ? "ADD" : "REMOVE"): place_\(place.id)")
        if willFavorite {
            favorites.insert(place.id)
        } else {
            favorites.remove(place.id)
        }
    }

    /// Deletes an item from the relevant store and updates in-memory state.
    private func performDelete() {
        // Stop playback if this pin is playing.
        if audio.currentTrackBaseName == track {
            audio.stop()
        }

        // Clean up user state tied to this pin.
        favorites.remove(place.id)
        recents.remove(kind: .place, itemID: place.id)
        pinAudioStore.clearSelection(for: pinKey)
        // Remove both new (media) and legacy (photo-only) attachments.
        mediaStore.removeAll(for: pinKey)
        photoStore.removeAllPhotos(for: pinKey)
        DeletedPinsStore.markDeleted(pinKey)

        // Remove from the backing data source.
        onDelete?()

        // Close the sheet / navigation.
        dismiss()
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Header row inside the card
                HStack(alignment: .top) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(place.name)
                            .font(.title3)
                            .fontWeight(.semibold)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(place.subtitle)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title3)
                            .foregroundStyle(isFavorite ? .red : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                }
                .padding(.top, headerTopPadding)
                .padding(.bottom, 6)

                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                    Text(trackTitle)
                        .font(.headline)
                    Spacer()
                }

                Button {
                    showSoundPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "music.note.list")
                        Text("Choose built-in sound")
                            .font(.subheadline)
                        Spacer()
                        if selectedSoundBaseName != nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(10)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                Text("Tap play to loop a short offline track for this place. Tracks are bundled locally (offline).")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                // MARK: User media (photos + videos)
                    PinMediaSection(title: "Media", pinKey: pinKey)

if onDelete != nil {
    Button(role: .destructive) {
        showDeleteConfirm = true
    } label: {
        HStack {
            Image(systemName: "trash")
            Text("Delete pin from map")
                .font(.headline)
            Spacer()
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    .buttonStyle(.plain)
    .alert("Delete this pin?", isPresented: $showDeleteConfirm) {
        Button("Delete", role: .destructive) { performDelete() }
        Button("Cancel", role: .cancel) { }
    } message: {
        Text("This will remove the pin and its saved photos/videos from the app.")
    }
}

                    Button {
                    // Record only when the user is effectively starting / switching playback.
                    if audio.currentTrackBaseName != track || !audio.isPlaying {
                        recents.record(place: place)
                    }
                    audio.toggle(trackBaseName: track, trackTitle: trackTitle, placeName: place.name)
                } label: {
                    HStack {
                        Image(systemName: (audio.isPlaying && audio.currentTrackBaseName == track) ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                        Text((audio.isPlaying && audio.currentTrackBaseName == track) ? "Pause" : "Play")
                            .font(.headline)
                        Spacer()
                    }
                    .padding(12)
                    .background(.thinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    audio.stop()
                } label: {
                    HStack {
                        Image(systemName: "stop.circle")
                        Text("Stop")
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }
            .padding(16)
        }
    }

    var body: some View {
        // Keep a navigation container for consistent sheet behavior, but we intentionally
        // do not show a navigation title or explicit close button.
        if #available(iOS 16.0, *) {
            NavigationStack { content }
                .sheet(isPresented: $showSoundPicker) {
                    BuiltInSoundPickerSheet(pinKey: pinKey, defaultTitle: place.audioTrackTitle)
                }
        } else {
            NavigationView { content }
                .sheet(isPresented: $showSoundPicker) {
                    BuiltInSoundPickerSheet(pinKey: pinKey, defaultTitle: place.audioTrackTitle)
                }
        }
    }
}



/// Sheet UI used to select a built-in ambient sound for a place.
struct BuiltInSoundPickerSheet: View {
    let pinKey: String
    let defaultTitle: String

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var pinAudioStore: PinAudioSelectionStore
    @ObservedObject private var audio = AudioManager.shared

    private var currentSelection: String? {
        pinAudioStore.selection(for: pinKey)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        pinAudioStore.clearSelection(for: pinKey)
                        audio.stopPreview()
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use default")
                                    .font(.headline)
                                Text(defaultTitle)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if currentSelection == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                Section("Built-in sounds") {
                    ForEach(BuiltInSoundLibrary.sounds) { sound in
                        Button {
                            pinAudioStore.setSelection(sound.baseName, for: pinKey)
                            audio.stopPreview()
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sound.title)
                                        .font(.headline)
                                    Text(sound.subtitle)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()

                                Button {
                                    audio.togglePreview(trackBaseName: sound.baseName)
                                } label: {
                                    Image(systemName: (audio.isPreviewing && audio.previewTrackBaseName == sound.baseName) ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel((audio.isPreviewing && audio.previewTrackBaseName == sound.baseName) ? "Stop preview" : "Play preview")
                                .accessibilityHint("Preview \(sound.title)")

                                if currentSelection == sound.baseName {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Choose sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        audio.stopPreview()
                        dismiss()
                    }
                }
            }
        }
    }
}


// MARK: - Bottom mini player

/// A lightweight bottom play bar that stays visible across the app.
/// Shows the current place + track and lets the user play/pause/stop.

// StationMusicModalView renders a custom interface component for this feature area.
struct StationMusicModalView: View {
    let station: RadioStation
    @Binding var favorites: Set<String>
    @Binding var detent: PresentationDetent

    /// Optional: when provided, shows a destructive "Delete pin" button.
    /// The caller should remove the pin from its backing array (e.g. stations.removeAll { ... }).
    let onDelete: (() -> Void)?

    @ObservedObject private var audio = AudioManager.shared
    @EnvironmentObject private var recents: RecentManager
    @EnvironmentObject private var photoStore: PinPhotoStore
    @Environment(\.dismiss) private var dismiss

    @State private var showDeleteConfirm = false
    // No explicit close button: the sheet is dismissed by pulling down or tapping outside.

    init(
        station: RadioStation,
        favorites: Binding<Set<String>> = .constant([]),
        detent: Binding<PresentationDetent> = .constant(.height(340)),
        onDelete: (() -> Void)? = nil
    ) {
        self.station = station
        self._favorites = favorites
        self._detent = detent
        self.onDelete = onDelete
    }

    private var stationFavoriteID: String { "station_" + station.id }
    private var isFavorite: Bool { favorites.contains(stationFavoriteID) }
    private var pinKey: String { "station_" + station.id }

    private let compactDetent: PresentationDetent = .height(340)
    private var isCompact: Bool { detent == compactDetent }

    private var hasPhotos: Bool {
        !photoStore.filenames(for: pinKey).isEmpty
    }

    private var headerTopPadding: CGFloat {
        if isCompact {
            return hasPhotos ? 32 : 20
        }
        return 12
    }

    /// Toggles the favorite state for an item and persists the change.
    private func toggleFavorite() {
        let willFavorite = !isFavorite
        AppLog.action("Favorite \(willFavorite ? "ADD" : "REMOVE"): \(stationFavoriteID)")
        if willFavorite {
            favorites.insert(stationFavoriteID)
        } else {
            favorites.remove(stationFavoriteID)
        }
    }

    /// Deletes an item from the relevant store and updates in-memory state.
    private func performDelete() {
        // Stop playback if this station is playing.
        if audio.currentStreamURLString == station.streamURL {
            audio.stop()
        }

        // Clean up user state tied to this pin.
        favorites.remove(stationFavoriteID)
        recents.remove(kind: .station, itemID: station.id)
        photoStore.removeAllPhotos(for: pinKey)
        DeletedPinsStore.markDeleted(pinKey)

        // Remove from backing source.
        onDelete?()

        dismiss()
    }

    private var locationText: String {
        "\(station.city), \(station.country)"
    }

    private var briefText: String {
        station.briefDescription ?? station.description
    }

    private var nowPlayingLabel: String {
        let live = "Live stream"
        guard audio.currentStreamURLString == station.streamURL else { return live }
        let now = (audio.nowPlayingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return now.isEmpty ? live : now
    }

    private var streamURLValue: URL? {
        URL(string: station.streamURL)
    }

    // Copies stream url for this feature.
    private func copyStreamURL() {
        UIPasteboard.general.string = station.streamURL
        AppLog.action("Copied stream URL for station: \(station.id)")
        if let url = streamURLValue {
            AppLog.url("Copied stream URL", url)
        }
    }

    // Opens stream url for this feature.
    private func openStreamURL() {
        guard let url = streamURLValue else {
            AppLog.info("Invalid stream URL for station \(station.id): \(station.streamURL)")
            return
        }
        AppLog.action("Open stream URL externally for station: \(station.id)")
        AppLog.url("Open station stream URL", url)
        UIApplication.shared.open(url)
    }

    @ViewBuilder
    private var stationLogoView: some View {
        StationLogoView(logoURLString: station.logoURL)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        stationLogoView
                            .frame(width: 42, height: 42)
                            .padding(6)
                            .background(.ultraThinMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                        VStack(alignment: .leading, spacing: 6) {
                            Text(station.name)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(locationText)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer()

                        Button(action: toggleFavorite) {
                            Image(systemName: isFavorite ? "heart.fill" : "heart")
                                .font(.title3)
                                .foregroundStyle(isFavorite ? .red : .primary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
                    }
                    .padding(.top, headerTopPadding)
                    .padding(.bottom, 6)

                    Text(briefText)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(3)

                    Text("Now Playing: \(nowPlayingLabel)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    PinPhotoSection(title: "Photos", pinKey: pinKey)

                    Button {
                        // Record only when the user is effectively starting / switching playback.
                        if audio.currentStreamURLString != station.streamURL || !audio.isPlaying {
                            recents.record(station: station)
                        }
                        audio.toggleStream(
                            urlString: station.streamURL,
                            trackTitle: station.name,
                            // Mini player subtitle: country.
                            placeName: station.country
                        )
                    } label: {
                        HStack {
                            Image(systemName: (audio.isPlaying && audio.currentStreamURLString == station.streamURL) ? "pause.fill" : "play.fill")
                            Text((audio.isPlaying && audio.currentStreamURLString == station.streamURL) ? "Pause" : "Play")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.borderedProminent)

                    HStack(spacing: 10) {
                        Button(action: copyStreamURL) {
                            Label("Copy Stream URL", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityHint("Copies the live stream link to the clipboard")
                        .accessibilityIdentifier("copy_stream_url")

                        Button(action: openStreamURL) {
                            Label("Open Stream URL", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(streamURLValue == nil)
                        .opacity(streamURLValue == nil ? 0.45 : 1.0)
                        .accessibilityHint("Opens the live stream link in another app")
                        .accessibilityIdentifier("open_stream_url")
                    }
                }
                .padding(16)
            }
        }
    }
}



/// Persistent mini player that shows the current playback state and quick controls.
struct MiniPlayerBar: View {
    @Binding var favorites: Set<String>
    @ObservedObject private var audio = AudioManager.shared

    // Local cache to resolve a station logo from the current stream URL.
    // This avoids threading station arrays through multiple view layers.
    @State private var stations: [RadioStation] = {
        let deleted = DeletedPinsStore.get()
        return RadioStationStore.load().filter { !deleted.contains("station_" + $0.id) }
    }()

    @State private var places: [Place] = {
            let deleted = DeletedPinsStore.get()
            return (PlaceStore.load() + UserPlaceStore.load())
                .filter { !deleted.contains("place_" + $0.id) }
        }()

    private var hasSelection: Bool {
        audio.currentTrackBaseName != nil || audio.currentStreamURLString != nil
    }

    private var currentStation: RadioStation? {
        guard let url = audio.currentStreamURLString else { return nil }
        return stations.first(where: { $0.streamURL == url })
    }

    private var currentSubtitle: String {
        if audio.currentStreamURLString != nil {
            let country = (audio.currentPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let now = (audio.nowPlayingText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = now.isEmpty ? "Live stream" : now
            if country.isEmpty {
                return meta
            }
            return "\(country) · \(meta)"
        }
        return audio.currentPlaceName ?? ""
    }

    private var favoriteTargetID: String? {
        // Radio stream: favorite the station.
        if audio.currentStreamURLString != nil, let station = currentStation {
            return "station_" + station.id
        }

        // Local track: favorite the place that initiated playback (when we can resolve it).
        guard audio.currentStreamURLString == nil else { return nil }

        let name = (audio.currentPlaceName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return places.first(where: { $0.name == name })?.id
    }

    private var isFavoriteInBar: Bool {
        guard let id = favoriteTargetID else { return false }
        return favorites.contains(id)
    }

    /// Toggles favorite state for the currently playing item from the mini player.
    private func toggleFavoriteInBar() {
        guard let id = favoriteTargetID else { return }
        let willFavorite = !favorites.contains(id)
        AppLog.action("Favorite (play bar) \(willFavorite ? "ADD" : "REMOVE"): \(id)")
        if willFavorite {
            favorites.insert(id)
        } else {
            favorites.remove(id)
        }
    }




    var body: some View {
        if hasSelection {
            HStack(spacing: 12) {
                if audio.currentStreamURLString != nil {
                    StationLogoView(logoURLString: currentStation?.logoURL)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    // For UChicago pins/local music we keep the default icon.
                    // For radio streams without a logo, fall back to the radio symbol.
                    Image(systemName: audio.currentStreamURLString == nil ? "music.note" : "dot.radiowaves.left.and.right")
                        .font(.title3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.currentTrackTitle ?? "Now Playing")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(currentSubtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    toggleFavoriteInBar()
                } label: {
                    Image(systemName: isFavoriteInBar ? "heart.fill" : "heart")
                        .font(.title3)
                        .foregroundStyle(isFavoriteInBar ? .red : .primary)
                }
                .buttonStyle(.borderless)
                .disabled(favoriteTargetID == nil)
                .opacity(favoriteTargetID == nil ? 0.4 : 1.0)
                .accessibilityLabel(isFavoriteInBar ? "Remove from favorites" : "Add to favorites")

                if audio.currentStreamURLString != nil && audio.isBuffering {
                    ProgressView()
                        .scaleEffect(0.75)
                        .accessibilityLabel("Connecting")
                }

                Button {
                    audio.isPlaying ? audio.pause() : audio.resume()
                } label: {
                    Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(audio.isPlaying ? "Pause" : "Play")
                .accessibilityHint("Toggles audio playback")

                Button {
                    audio.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop")
                .accessibilityHint("Stops playback")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(radius: 10)
            .padding(.horizontal, 12)
        }
    }
}


/// Reusable view shown when a list has no content to display.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

// MARK: - Places list (Places tab)

/// The Places tab list view (All/Favorites + category chips + search).
/// This was referenced by `RootView` but missing in the radio-stations build.
struct PlacesListView: View {
    @Binding var places: [Place]
    @Binding var stations: [RadioStation]
    @Binding var favorites: Set<String>

    @State private var searchText: String = ""
    @State private var scope: ListScope = .all

    /// Horizontal filter control for selecting a place category.
    private enum CategoryFilter: Hashable {
        case all
        case place(PlaceCategory)
        case radio

        var label: String {
            switch self {
            case .all: return "All Categories"
            case .place(let c): return c.displayName
            case .radio: return "Radio"
            }
        }
    }

    @State private var selectedFilter: CategoryFilter = .all
    @State private var categoryRefreshTick: Int = 0
    @State private var selectedStationCountry: String = "All Countries"
    @State private var selectedStationRegion: String = "All Regions"
    @State private var selectedStationLanguage: String = "All Languages"
    @State private var selectedStationMood: String = "All Moods"
    @State private var stationSort: StationSortOption = .alphabetical
    @State private var savedJourneys: [ListeningJourney] = ListeningJourneyStore.get()
    @State private var journeyPendingRename: ListeningJourney?
    @State private var renameJourneyDraft: String = ""
    @State private var isRenameJourneyPromptPresented: Bool = false

    @EnvironmentObject private var recents: RecentManager
    @StateObject private var locationManager = LocationManager()

    private static let allCountriesLabel = "All Countries"
    private static let allRegionsLabel = "All Regions"
    private static let allLanguagesLabel = "All Languages"
    private static let allMoodsLabel = "All Moods"

    /// Computes the favorites identifier used for a station.
    private func stationFavoriteID(_ s: RadioStation) -> String { "station_" + s.id }

    private var placeCategories: [PlaceCategory] {
        Array(Set(places.map { $0.effectiveCategory })).sorted { $0.displayName < $1.displayName }
    }

    private var favoritePlaces: [Place] {
        places.filter { favorites.contains($0.id) }
    }

    private var favoriteStations: [RadioStation] {
        stations.filter { favorites.contains(stationFavoriteID($0)) }
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var showsRadioDiscoveryControls: Bool {
        switch selectedFilter {
        case .all, .radio:
            return true
        case .place:
            return false
        }
    }

    private var availableStationCountries: [String] {
        Array(Set(stations.map { $0.country }.filter { !$0.isEmpty })).sorted()
    }

    private var availableStationRegions: [String] {
        Array(Set(stations.map { $0.worldRegion })).sorted()
    }

    private var availableStationLanguages: [String] {
        RadioStation.availableLanguageLabels(in: stations)
    }

    private var availableStationMoods: [String] {
        RadioStation.availableMoodLabels(in: stations)
    }

    private var builtInJourneys: [ListeningJourney] {
        [
            ListeningJourney(
                id: "builtin_late_night_study",
                title: "Late-night Study",
                country: nil,
                region: nil,
                language: nil,
                mood: nil,
                sortOption: .studyFriendly
            ),
            ListeningJourney(
                id: "builtin_calm_city_radio",
                title: "Calm City Radio",
                country: nil,
                region: nil,
                language: nil,
                mood: availableStationMoods.contains("Music") ? "Music" : nil,
                sortOption: .studyFriendly
            ),
            ListeningJourney(
                id: "builtin_morning_world_tour",
                title: "Morning World Tour",
                country: nil,
                region: availableStationRegions.contains("Americas") ? "Americas" : nil,
                language: nil,
                mood: nil,
                sortOption: .alphabetical
            )
        ]
    }

    // Evaluates passes discovery filters for this feature.
    private func stationPassesDiscoveryFilters(_ station: RadioStation) -> Bool {
        if selectedStationCountry != Self.allCountriesLabel && station.country != selectedStationCountry {
            return false
        }

        if selectedStationRegion != Self.allRegionsLabel && station.worldRegion != selectedStationRegion {
            return false
        }

        if selectedStationLanguage != Self.allLanguagesLabel && !station.languageLabels.contains(selectedStationLanguage) {
            return false
        }

        if selectedStationMood != Self.allMoodsLabel && !station.moodGenreLabels.contains(selectedStationMood) {
            return false
        }

        return true
    }

    // Handles stations for this feature.
    private func sortStations(_ input: [RadioStation]) -> [RadioStation] {
        let recentOrder = Dictionary(uniqueKeysWithValues: recents.items.enumerated().compactMap { entry in
            entry.element.kind == .station ? (entry.element.itemID, entry.offset) : nil
        })

        return input.sorted { lhs, rhs in
            switch stationSort {
            case .alphabetical:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending

            case .favoritesFirst:
                let lhsFavorite = favorites.contains(stationFavoriteID(lhs))
                let rhsFavorite = favorites.contains(stationFavoriteID(rhs))
                if lhsFavorite != rhsFavorite {
                    return lhsFavorite && !rhsFavorite
                }

            case .recentFirst:
                let lhsRecent = recentOrder[lhs.id] ?? Int.max
                let rhsRecent = recentOrder[rhs.id] ?? Int.max
                if lhsRecent != rhsRecent {
                    return lhsRecent < rhsRecent
                }

            case .studyFriendly:
                if lhs.isStudyFriendly != rhs.isStudyFriendly {
                    return lhs.isStudyFriendly && !rhs.isStudyFriendly
                }

            case .nearestFirst:
                guard let userCoordinate = locationManager.coordinate else {
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                let lhsDistance = lhs.distance(from: userCoordinate) ?? Double.greatestFiniteMagnitude
                let rhsDistance = rhs.distance(from: userCoordinate) ?? Double.greatestFiniteMagnitude
                if lhsDistance != rhsDistance {
                    return lhsDistance < rhsDistance
                }
            }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    // Applies journey for this feature.
    private func applyJourney(_ journey: ListeningJourney) {
        selectedFilter = .radio
        selectedStationCountry = journey.country ?? Self.allCountriesLabel
        selectedStationRegion = journey.region ?? Self.allRegionsLabel
        selectedStationLanguage = journey.language ?? Self.allLanguagesLabel
        selectedStationMood = journey.mood ?? Self.allMoodsLabel
        stationSort = journey.sortOption
        AppLog.action("Apply listening journey: \(journey.title)")

        if journey.sortOption == .nearestFirst {
            locationManager.requestOneShotLocation()
        }
    }

    // Handles matches current for this feature.
    private func journeyMatchesCurrent(_ journey: ListeningJourney) -> Bool {
        (journey.country ?? Self.allCountriesLabel) == selectedStationCountry &&
        (journey.region ?? Self.allRegionsLabel) == selectedStationRegion &&
        (journey.language ?? Self.allLanguagesLabel) == selectedStationLanguage &&
        (journey.mood ?? Self.allMoodsLabel) == selectedStationMood &&
        journey.sortOption == stationSort
    }

    // Builds journey title for this feature.
    private func generatedJourneyTitle() -> String {
        var components: [String] = []

        if selectedStationMood != Self.allMoodsLabel {
            components.append(selectedStationMood)
        }
        if selectedStationLanguage != Self.allLanguagesLabel {
            components.append(selectedStationLanguage)
        }
        if selectedStationCountry != Self.allCountriesLabel {
            components.append(selectedStationCountry)
        } else if selectedStationRegion != Self.allRegionsLabel {
            components.append(selectedStationRegion)
        }

        if components.isEmpty {
            switch stationSort {
            case .studyFriendly:
                return "Late-night Study"
            case .favoritesFirst:
                return "Favorite Radio Mix"
            case .recentFirst:
                return "Recent Radio Mix"
            case .nearestFirst:
                return "Nearby Radio Mix"
            case .alphabetical:
                return "My Radio Journey"
            }
        }

        let base = components.prefix(2).joined(separator: " ")
        switch stationSort {
        case .studyFriendly:
            return base + " Study Mix"
        case .nearestFirst:
            return "Nearby " + base
        case .favoritesFirst:
            return base + " Favorites"
        default:
            return base + " Journey"
        }
    }

    // Builds journey title for this feature.
    private func uniqueJourneyTitle(_ proposed: String, excludingID excludedID: String? = nil) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "My Radio Journey" : trimmed
        let existing = Set(savedJourneys.filter { $0.id != excludedID }.map { $0.title.lowercased() })
        guard existing.contains(base.lowercased()) else { return base }

        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    // Saves current journey for this feature.
    private func saveCurrentJourney() {
        let title = uniqueJourneyTitle(generatedJourneyTitle())
        let journey = ListeningJourney(
            id: UUID().uuidString,
            title: title,
            country: selectedStationCountry == Self.allCountriesLabel ? nil : selectedStationCountry,
            region: selectedStationRegion == Self.allRegionsLabel ? nil : selectedStationRegion,
            language: selectedStationLanguage == Self.allLanguagesLabel ? nil : selectedStationLanguage,
            mood: selectedStationMood == Self.allMoodsLabel ? nil : selectedStationMood,
            sortOption: stationSort
        )

        ListeningJourneyStore.save(journey)
        savedJourneys = ListeningJourneyStore.get()
        AppLog.action("Saved listening journey: \(title)")
    }

    private var discoveryFiltersAreDefault: Bool {
        selectedStationCountry == Self.allCountriesLabel &&
        selectedStationRegion == Self.allRegionsLabel &&
        selectedStationLanguage == Self.allLanguagesLabel &&
        selectedStationMood == Self.allMoodsLabel &&
        stationSort == .alphabetical
    }

    private var radioDiscoveryMatchCount: Int {
        scope == .favorites ? filteredFavoriteStations.count : filteredStationsAllScope.count
    }

    private var activeDiscoverySummary: String {
        var parts: [String] = []

        if scope == .favorites {
            parts.append("Favorites scope")
        }

        if selectedStationCountry != Self.allCountriesLabel {
            parts.append("Country: \(selectedStationCountry)")
        }
        if selectedStationRegion != Self.allRegionsLabel {
            parts.append("Region: \(selectedStationRegion)")
        }
        if selectedStationLanguage != Self.allLanguagesLabel {
            parts.append("Language: \(selectedStationLanguage)")
        }
        if selectedStationMood != Self.allMoodsLabel {
            parts.append("Mood: \(selectedStationMood)")
        }

        parts.append("Sort: \(stationSort.rawValue)")
        return parts.joined(separator: " • ")
    }

    // Duplicates saved journey for this feature.
    private func duplicateSavedJourney(_ journey: ListeningJourney) {
        let duplicatedTitle = uniqueJourneyTitle("\(journey.title) Copy")
        let duplicatedJourney = ListeningJourney(
            id: UUID().uuidString,
            title: duplicatedTitle,
            country: journey.country,
            region: journey.region,
            language: journey.language,
            mood: journey.mood,
            sortOption: journey.sortOption
        )

        ListeningJourneyStore.save(duplicatedJourney)
        savedJourneys = ListeningJourneyStore.get()
        AppLog.action("Duplicated listening journey: \(journey.title) -> \(duplicatedTitle)")
    }

    // Resets discovery filters for this feature.
    private func resetDiscoveryFilters() {
        AppLog.action("Reset radio discovery filters")
        selectedStationCountry = Self.allCountriesLabel
        selectedStationRegion = Self.allRegionsLabel
        selectedStationLanguage = Self.allLanguagesLabel
        selectedStationMood = Self.allMoodsLabel
        stationSort = .alphabetical
    }

    // Handles saved journey for this feature.
    private func deleteSavedJourney(_ journey: ListeningJourney) {
        ListeningJourneyStore.remove(id: journey.id)
        savedJourneys = ListeningJourneyStore.get()
    }

    // Starts renaming journey for this feature.
    private func startRenamingJourney(_ journey: ListeningJourney) {
        journeyPendingRename = journey
        renameJourneyDraft = journey.title
        isRenameJourneyPromptPresented = true
        AppLog.action("Selected rename for listening journey: \(journey.title)")
    }

    // Cancels journey rename for this feature.
    private func cancelJourneyRename() {
        if let journeyPendingRename {
            AppLog.info("Cancelled listening journey rename: \(journeyPendingRename.title)")
        }
        journeyPendingRename = nil
        renameJourneyDraft = ""
        isRenameJourneyPromptPresented = false
    }

    // Commits journey rename for this feature.
    private func commitJourneyRename() {
        guard let journeyPendingRename else {
            renameJourneyDraft = ""
            isRenameJourneyPromptPresented = false
            return
        }

        let resolvedTitle = uniqueJourneyTitle(renameJourneyDraft, excludingID: journeyPendingRename.id)
        _ = ListeningJourneyStore.rename(id: journeyPendingRename.id, to: resolvedTitle)
        savedJourneys = ListeningJourneyStore.get()
        self.journeyPendingRename = nil
        renameJourneyDraft = ""
        isRenameJourneyPromptPresented = false
    }

    @ViewBuilder
    // Builds pill for this feature.
    private func discoveryPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    // Handles pill for this feature.
    private func journeyPill(title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.05), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Returns true when an item matches the current search query.
    private func matchesSearch(place: Place, query q: String) -> Bool {
        place.name.lowercased().contains(q) ||
        place.subtitle.lowercased().contains(q) ||
        place.effectiveCategory.rawValue.contains(q)
    }

    /// Returns true when an item matches the current search query.
    private func matchesSearch(station: RadioStation, query q: String) -> Bool {
        station.name.lowercased().contains(q) ||
        station.city.lowercased().contains(q) ||
        station.country.lowercased().contains(q) ||
        station.description.lowercased().contains(q) ||
        (station.briefDescription ?? "").lowercased().contains(q)
    }

    private var filteredPlacesAllScope: [Place] {
        var result = places

        // Category (only applies to place categories)
        if case .place(let cat) = selectedFilter {
            result = result.filter { $0.effectiveCategory == cat }
        }

        // Search
        if !trimmedQuery.isEmpty {
            result = result.filter { matchesSearch(place: $0, query: trimmedQuery) }
        }

        return result.sorted { $0.name < $1.name }
    }

    private var filteredStationsAllScope: [RadioStation] {
        var result = stations

        // Category
        if case .radio = selectedFilter {
            // keep
        } else if case .all = selectedFilter {
            // keep
        } else {
            // Place category selected -> no stations
            result = []
        }

        result = result.filter { stationPassesDiscoveryFilters($0) }

        // Search
        if !trimmedQuery.isEmpty {
            result = result.filter { matchesSearch(station: $0, query: trimmedQuery) }
        }

        return sortStations(result)
    }

    private var filteredFavoritePlaces: [Place] {
        var result = favoritePlaces

        if case .place(let cat) = selectedFilter {
            result = result.filter { $0.effectiveCategory == cat }
        } else if case .radio = selectedFilter {
            result = []
        }

        if !trimmedQuery.isEmpty {
            result = result.filter { matchesSearch(place: $0, query: trimmedQuery) }
        }

        return result.sorted { $0.name < $1.name }
    }

    private var filteredFavoriteStations: [RadioStation] {
        var result = favoriteStations

        if case .radio = selectedFilter {
            // keep
        } else if case .all = selectedFilter {
            // keep
        } else {
            // place category selected -> no stations
            result = []
        }

        result = result.filter { stationPassesDiscoveryFilters($0) }

        if !trimmedQuery.isEmpty {
            result = result.filter { matchesSearch(station: $0, query: trimmedQuery) }
        }

        return sortStations(result)
    }

    var body: some View {
        List {
            if showsRadioDiscoveryControls {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Radio discovery")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Menu {
                                    Button(Self.allCountriesLabel) {
                                        selectedStationCountry = Self.allCountriesLabel
                                    }
                                    ForEach(availableStationCountries, id: \.self) { country in
                                        Button(country) {
                                            selectedStationCountry = country
                                        }
                                    }
                                } label: {
                                    discoveryPill(title: "Country", value: selectedStationCountry)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("Country filter")
                                        .accessibilityValue(selectedStationCountry)
                                        .accessibilityHint("Opens the list of available countries")
                                        .accessibilityIdentifier("country_filter")
                                }

                                Menu {
                                    Button(Self.allRegionsLabel) {
                                        selectedStationRegion = Self.allRegionsLabel
                                    }
                                    ForEach(availableStationRegions, id: \.self) { region in
                                        Button(region) {
                                            selectedStationRegion = region
                                        }
                                    }
                                } label: {
                                    discoveryPill(title: "Region", value: selectedStationRegion)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("Region filter")
                                        .accessibilityValue(selectedStationRegion)
                                        .accessibilityHint("Opens the list of available world regions")
                                        .accessibilityIdentifier("region_filter")
                                }

                                Menu {
                                    Button(Self.allLanguagesLabel) {
                                        selectedStationLanguage = Self.allLanguagesLabel
                                    }
                                    ForEach(availableStationLanguages, id: \.self) { language in
                                        Button(language) {
                                            selectedStationLanguage = language
                                        }
                                    }
                                } label: {
                                    discoveryPill(title: "Language", value: selectedStationLanguage)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("Language filter")
                                        .accessibilityValue(selectedStationLanguage)
                                        .accessibilityHint("Opens the list of available languages")
                                        .accessibilityIdentifier("language_filter")
                                }

                                Menu {
                                    Button(Self.allMoodsLabel) {
                                        selectedStationMood = Self.allMoodsLabel
                                    }
                                    ForEach(availableStationMoods, id: \.self) { mood in
                                        Button(mood) {
                                            selectedStationMood = mood
                                        }
                                    }
                                } label: {
                                    discoveryPill(title: "Mood and genre filter", value: selectedStationMood)
                                        .accessibilityElement(children: .ignore)
                                        .accessibilityLabel("Mood and genre filter")
                                        .accessibilityValue(selectedStationMood)
                                        .accessibilityHint("Opens the list of available mood and genre tags")
                                }
                            }
                            .padding(.vertical, 2)
                            .fixedSize(horizontal: true, vertical: false)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Menu {
                                ForEach(StationSortOption.allCases) { option in
                                    Button(option.rawValue) {
                                        stationSort = option
                                    }
                                }
                            } label: {
                                discoveryPill(title: "Sort", value: stationSort.rawValue)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel("Sort stations")
                                    .accessibilityValue(stationSort.rawValue)
                                    .accessibilityHint("Opens the available station sorting options")
                                    .accessibilityIdentifier("station_sort")
                            }

                            HStack(spacing: 8) {
                                Button {
                                    saveCurrentJourney()
                                } label: {
                                    Label("Save current mix", systemImage: "square.and.arrow.down")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.9)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .accessibilityHint("Saves the current radio discovery filters as a reusable preset")
                                .accessibilityIdentifier("save_current_mix")

                                Button {
                                    resetDiscoveryFilters()
                                } label: {
                                    Label("Reset filters", systemImage: "arrow.counterclockwise")
                                        .font(.subheadline.weight(.semibold))
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.9)
                                        .frame(maxWidth: .infinity)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(Color.primary.opacity(0.06), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .frame(maxWidth: .infinity)
                                .disabled(discoveryFiltersAreDefault)
                                .opacity(discoveryFiltersAreDefault ? 0.45 : 1.0)
                                .accessibilityLabel("Reset radio discovery filters")
                                .accessibilityValue(discoveryFiltersAreDefault ? "No custom filters applied" : "Custom filters applied")
                                .accessibilityHint("Clears the country, region, language, mood, and sort selections")
                                .accessibilityIdentifier("reset_discovery_filters")
                            }
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Label("\(radioDiscoveryMatchCount) matching station\(radioDiscoveryMatchCount == 1 ? "" : "s")", systemImage: "dot.radiowaves.left.and.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(activeDiscoverySummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Matching stations")
                        .accessibilityValue("\(radioDiscoveryMatchCount) station\(radioDiscoveryMatchCount == 1 ? "" : "s")")
                        .accessibilityHint(activeDiscoverySummary)
                        .accessibilityIdentifier("radio_discovery_summary")

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(builtInJourneys) { journey in
                                    Button {
                                        applyJourney(journey)
                                    } label: {
                                        journeyPill(title: journey.title, isSelected: journeyMatchesCurrent(journey))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Apply \(journey.title)")
                                    .accessibilityValue(journeyMatchesCurrent(journey) ? "Selected" : "Not selected")
                                    .accessibilityHint("Applies this listening journey preset")
                                }

                                ForEach(savedJourneys) { journey in
                                    Button {
                                        applyJourney(journey)
                                    } label: {
                                        journeyPill(title: journey.title, isSelected: journeyMatchesCurrent(journey))
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button {
                                            startRenamingJourney(journey)
                                        } label: {
                                            Label("Rename saved journey", systemImage: "pencil")
                                        }

                                        Button {
                                            duplicateSavedJourney(journey)
                                        } label: {
                                            Label("Duplicate saved journey", systemImage: "plus.square.on.square")
                                        }

                                        Button(role: .destructive) {
                                            deleteSavedJourney(journey)
                                        } label: {
                                            Label("Delete saved journey", systemImage: "trash")
                                        }
                                    }
                                    .accessibilityLabel("Apply \(journey.title)")
                                    .accessibilityValue(journeyMatchesCurrent(journey) ? "Selected" : "Not selected")
                                    .accessibilityHint("Applies this listening journey preset. Touch and hold for rename, duplicate, and delete actions.")
                                    .accessibilityAction(named: Text("Rename journey")) {
                                        startRenamingJourney(journey)
                                    }
                                    .accessibilityAction(named: Text("Duplicate journey")) {
                                        duplicateSavedJourney(journey)
                                    }
                                    .accessibilityAction(named: Text("Delete journey")) {
                                        deleteSavedJourney(journey)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                            .fixedSize(horizontal: true, vertical: false)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowSeparator(.hidden)
            }

            // Category chips
            // Show a horizontal scroll indicator so users know there are more categories off-screen.
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 8) {
                    Button {
                        selectedFilter = .all
                    } label: {
                        Text(CategoryFilter.all.label)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedFilter == .all ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .accessibilityLabel(CategoryFilter.all.label)
                    .accessibilityValue(selectedFilter == .all ? "Selected" : "Not selected")
                    .accessibilityHint("Shows all places and radio categories")

                    ForEach(placeCategories, id: \.self) { cat in
                        Button {
                            selectedFilter = .place(cat)
                        } label: {
                            Text(cat.displayName)
                                .font(.subheadline)
                                .lineLimit(1)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedFilter == .place(cat) ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                                .clipShape(Capsule())
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .accessibilityLabel(cat.displayName)
                        .accessibilityValue(selectedFilter == .place(cat) ? "Selected" : "Not selected")
                        .accessibilityHint("Filters the list to the \(cat.displayName) category")
                    }

                    // Radio category (shows stations in the All list and Favorites list).
                    Button {
                        selectedFilter = .radio
                    } label: {
                        Text(CategoryFilter.radio.label)
                            .font(.subheadline)
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(selectedFilter == .radio ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
                            .clipShape(Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .accessibilityLabel(CategoryFilter.radio.label)
                    .accessibilityValue(selectedFilter == .radio ? "Selected" : "Not selected")
                    .accessibilityHint("Filters the list to radio stations")
                }
                .padding(.vertical, 4)
                .fixedSize(horizontal: true, vertical: false)
                .buttonStyle(.plain)
            }
            .scrollIndicators(.visible)
            .listRowSeparator(.hidden)

            if scope == .all {
        let allPlaces = filteredPlacesAllScope
        let allStations = filteredStationsAllScope

        if places.isEmpty && stations.isEmpty {
            EmptyStateView(
                title: "No items",
                systemImage: "exclamationmark.triangle",
                message: "Make sure places.json and stations.json are included in your app bundle."
            )
            .listRowSeparator(.hidden)
        } else if selectedFilter == .radio {
            if allStations.isEmpty {
                EmptyStateView(
                    title: "No radio stations",
                    systemImage: "dot.radiowaves.left.and.right",
                    message: "No stations match your search."
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(allStations) { s in
                    NavigationLink {
                        StationMusicModalView(station: s, favorites: $favorites)
                    } label: {
                        StationRow(station: s, favorites: $favorites)
                    }
                    .cardListRowStyle()
                }
            }
        } else if case .place = selectedFilter {
            if allPlaces.isEmpty {
                EmptyStateView(
                    title: "No places",
                    systemImage: "map",
                    message: "No places match your search."
                )
                .listRowSeparator(.hidden)
            } else {
                ForEach(allPlaces, id: \.listRefreshID) { place in
                    NavigationLink {
                        PlaceDetailView(place: place, places: places, favorites: $favorites)
                    } label: {
                        PlaceRow(place: place, favorites: $favorites)
                    }
                    .cardListRowStyle()
                }
            }
        } else {
            // All Categories -> show both
            if allStations.isEmpty && allPlaces.isEmpty {
                EmptyStateView(
                    title: "No results",
                    systemImage: "magnifyingglass",
                    message: "No places or radio stations match your search."
                )
                .listRowSeparator(.hidden)
            } else {
                if !allStations.isEmpty {
                    Section("Radio") {
                        ForEach(allStations) { s in
                            NavigationLink {
                                StationMusicModalView(station: s, favorites: $favorites)
                            } label: {
                                StationRow(station: s, favorites: $favorites)
                            }
                    .cardListRowStyle()
                        }
                    }
                }

                if !allPlaces.isEmpty {
                    Section("Places") {
                        ForEach(allPlaces, id: \.listRefreshID) { place in
                            NavigationLink {
                                PlaceDetailView(place: place, places: places, favorites: $favorites)
                            } label: {
                                PlaceRow(place: place, favorites: $favorites)
                            }
                    .cardListRowStyle()
                        }
                    }
                }
            }
        }
            } else {
                // Favorites scope (places + radio stations)
                let favPlaces = filteredFavoritePlaces
                let favStations = filteredFavoriteStations

                if favPlaces.isEmpty && favStations.isEmpty {
                    EmptyStateView(
                        title: "No favorites yet",
                        systemImage: "heart",
                        message: "Tap the heart on a place card or a radio station card to add it here."
                    )
                    .listRowSeparator(.hidden)
                } else {
                    if selectedFilter == .all {
                        if !favStations.isEmpty {
                            Section("Radio") {
                                ForEach(favStations) { s in
                                    NavigationLink {
                                        StationMusicModalView(station: s, favorites: $favorites)
                                    } label: {
                                        StationRow(station: s, favorites: $favorites)
                                    }
                    .cardListRowStyle()
                                }
                            }
                        }

                        if !favPlaces.isEmpty {
                            Section("Places") {
                                ForEach(favPlaces, id: \.listRefreshID) { place in
                                    NavigationLink {
                                        PlaceDetailView(place: place, places: places, favorites: $favorites)
                                    } label: {
                                        PlaceRow(place: place, favorites: $favorites)
                                    }
                    .cardListRowStyle()
                                }
                            }
                        }
                    } else if selectedFilter == .radio {
                        ForEach(favStations) { s in
                            NavigationLink {
                                StationMusicModalView(station: s, favorites: $favorites)
                            } label: {
                                StationRow(station: s, favorites: $favorites)
                            }
                    .cardListRowStyle()
                        }
                    } else {
                        ForEach(favPlaces, id: \.listRefreshID) { place in
                            NavigationLink {
                                PlaceDetailView(place: place, places: places, favorites: $favorites)
                            } label: {
                                PlaceRow(place: place, favorites: $favorites)
                            }
                    .cardListRowStyle()
                        }
                    }
                }
            }
        }
        .navigationTitle("Places")
        .searchable(text: $searchText, prompt: "Search places or radio…")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Scope", selection: $scope) {
                    ForEach(ListScope.allCases) { s in
                        Text(s.rawValue).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
                .accessibilityLabel("List scope")
            }
        }
        .onChange(of: scope) { _, newValue in
            AppLog.action("Set places list scope: \(newValue.rawValue)")
        }
        .onChange(of: selectedFilter) { _, newValue in
            AppLog.action("Set places category filter: \(newValue.label)")
        }
        .onChange(of: selectedStationCountry) { _, newValue in
            AppLog.action("Set station country filter: \(newValue)")
        }
        .onChange(of: selectedStationRegion) { _, newValue in
            AppLog.action("Set station region filter: \(newValue)")
        }
        .onChange(of: selectedStationLanguage) { _, newValue in
            AppLog.action("Set station language filter: \(newValue)")
        }
        .onChange(of: selectedStationMood) { _, newValue in
            AppLog.action("Set station mood filter: \(newValue)")
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            AppLog.info(trimmed.isEmpty ? "Cleared places search query" : "Updated places search query: \(trimmed)")
        }
        .onChange(of: stationSort) { _, newValue in
            AppLog.action("Set station sort: \(newValue.rawValue)")
            if newValue == .nearestFirst {
                locationManager.requestOneShotLocation()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PlaceCategoryOverrideStore.didChangeNotification)) { notification in
            guard PlaceCategoryOverrideStore.changePayload(from: notification) != nil else { return }
            categoryRefreshTick &+= 1
        }
        .alert("Rename saved journey", isPresented: $isRenameJourneyPromptPresented) {
            TextField("Journey name", text: $renameJourneyDraft)
                .accessibilityLabel("Journey name")
                .accessibilityHint("Enter a new name for the saved listening journey")

            Button("Cancel", role: .cancel) {
                cancelJourneyRename()
            }

            Button("Save") {
                commitJourneyRename()
            }
        } message: {
            if let journeyPendingRename {
                Text("Update the saved preset name for \(journeyPendingRename.title).")
            } else {
                Text("Enter a new name for this saved listening journey.")
            }
        }
        // No-op: Radio is available in both scopes.
    }
}

/// Applies a consistent card-like style to rows embedded in a `List`.
struct CardListRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// Applies consistent insets/background for card-like rows inside a `List`.
    func cardListRowStyle() -> some View {
        modifier(CardListRowModifier())
    }
}

/// Card-like row view for displaying a place in a list.
struct PlaceRow: View {
    let place: Place
    @Binding var favorites: Set<String>

    /// When used outside a `NavigationLink` (e.g. inside a button that opens a sheet),
    /// show an explicit disclosure indicator to match the list styling.
    var showsDisclosure: Bool = false

    private var isFavorite: Bool { favorites.contains(place.id) }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: place.iconSystemName)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .foregroundStyle(.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(place.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(place.effectiveCategory.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                if isFavorite {
                    favorites.remove(place.id)
                } else {
                    favorites.insert(place.id)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .imageScale(.large)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            // Borderless prevents the tap from triggering the parent NavigationLink/Button.
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// Card-like row view for displaying a radio station in a list.
struct StationRow: View {
    let station: RadioStation
    @Binding var favorites: Set<String>

    /// When used outside a `NavigationLink` (e.g. inside a button that opens a sheet),
    /// show an explicit disclosure indicator to match the list styling.
    var showsDisclosure: Bool = false

    private var favoriteID: String { "station_" + station.id }
    private var isFavorite: Bool { favorites.contains(favoriteID) }

    var body: some View {
        HStack(spacing: 12) {
            // Prefer the station's logo if it exists, otherwise fall back to the default radio icon.
            AlamofireStationLogoView(logoURLString: station.logoURL)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(station.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(station.country)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text("Radio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button {
                if isFavorite {
                    favorites.remove(favoriteID)
                } else {
                    favorites.insert(favoriteID)
                }
            } label: {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .imageScale(.large)
                    .foregroundStyle(isFavorite ? .red : .primary)
            }
            // Borderless prevents the tap from triggering the parent NavigationLink/Button.
            .buttonStyle(.borderless)
            .accessibilityLabel(isFavorite ? "Unfavorite" : "Favorite")

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Small map used on the Place details screen

// PlaceMapView renders a custom interface component for this feature area.
struct PlaceMapView: View {
    @AppStorage("ra_mapIsSatellite") private var mapIsSatellite: Bool = true

    let place: Place
    @Binding var modalPlace: Place?

    @State private var cameraPosition: MapCameraPosition

    init(place: Place, modalPlace: Binding<Place?>) {
        self.place = place
        self._modalPlace = modalPlace
        let initial = MKCoordinateRegion(
            center: place.coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
        )
        _cameraPosition = State(initialValue: .region(initial))
    }

    var body: some View {
        Map(position: $cameraPosition) {
            Annotation(place.name, coordinate: place.coordinate, anchor: .bottom) {
                Button {
                    modalPlace = place
                } label: {
                    Image(systemName: "mappin.circle.fill")
                        .font(.title2)
                        .foregroundColor(.red)
                        .shadow(radius: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open place card")
            }
        }
        .mapStyle(mapIsSatellite ? .imagery : .standard)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}

// MARK: - Sleep Timer UI

// SleepTimerCountdownChip renders a custom interface component for this feature area.
struct SleepTimerCountdownChip: View {
    let remainingText: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "zzz")
                .font(.system(size: 13, weight: .semibold))
            Text(remainingText)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep timer remaining \(remainingText)")
    }
}

/// Sheet that lets the user select a sleep timer duration.
struct SleepTimerSheet: View {
    @Binding var isPresented: Bool
    @ObservedObject private var sleepTimer = SleepTimerManager.shared

    @State private var hours: Int = 0
    @State private var minutes: Int = 30

    private var totalMinutes: Int { hours * 60 + minutes }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Set sleep timer")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .padding(.top, 6)

                    HStack(spacing: 12) {
                        SleepTimerUnitPicker(
                            title: "hours",
                            values: Array(0...12),
                            selection: $hours
                        ) { value in
                            "\(value)"
                        }

                        SleepTimerUnitPicker(
                            title: "min",
                            values: Array(0...59),
                            selection: $minutes
                        ) { value in
                            String(format: "%02d", value)
                        }
                    }
                    .frame(height: 170)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )

                    if sleepTimer.isActive {
                        Button(role: .destructive) {
                            AppLog.action("Sleep timer sheet: cancel timer tapped")
                            sleepTimer.cancel()
                            isPresented = false
                        } label: {
                            Text("Cancel timer")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Cancel timer")
                        .accessibilityHint("Cancels the active sleep timer")
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )

                        Text("Current remaining: \(sleepTimer.formattedRemaining())")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }

                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            .navigationTitle("Sleep Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        AppLog.action("Sleep timer sheet: done tapped with \(hours) hours and \(minutes) minutes")
                        if totalMinutes > 0 {
                            sleepTimer.setTimer(minutes: totalMinutes)
                        } else {
                            AppLog.info("Sleep timer sheet: zero duration selected; closing without starting a timer")
                        }
                        isPresented = false
                    }
                    .accessibilityHint("Closes the sheet and starts the timer if the duration is greater than zero")
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            // If there is an active timer, initialize the wheels to the current remaining time.
            if sleepTimer.isActive {
                let s = max(0, sleepTimer.remainingSeconds)
                let h = min(12, s / 3600)
                let m = min(59, (s % 3600) / 60)
                hours = h
                minutes = m
            }
        }
    }
}

// SleepTimerUnitPicker renders a custom interface component for this feature area.
private struct SleepTimerUnitPicker: View {
    let title: String
    let values: [Int]
    @Binding var selection: Int
    let formatter: (Int) -> String

    var body: some View {
        HStack(spacing: 8) {
            Picker(title, selection: $selection) {
                ForEach(values, id: \.self) { value in
                    Text(formatter(value))
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(width: 72)
            .clipped()
            .accessibilityLabel(title)

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 64, alignment: .leading)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
    }
}
