import SwiftUI
import MapKit

struct RouteControls: View {
    @Environment(AppModel.self) private var app

    @State private var fromText = "My Location"
    @State private var toText = ""
    @State private var fromResults: [MKMapItem] = []
    @State private var toResults: [MKMapItem] = []
    @State private var fromCoordinate: CLLocationCoordinate2D? = nil

    enum Field { case from, to }
    @FocusState private var focused: Field?

    private var showSuggestions: Bool {
        (focused == .from && !fromResults.isEmpty) ||
        (focused == .to   && !toResults.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchCard
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, showSuggestions ? 0 : 8)

            if focused == .from && !fromResults.isEmpty {
                suggestionList(fromResults) { item in
                    fromText = item.name ?? ""
                    fromCoordinate = item.placemark.location?.coordinate
                    fromResults = []
                    focused = .to
                }
            } else if focused == .to && !toResults.isEmpty {
                suggestionList(toResults) { item in
                    toText = item.name ?? ""
                    toResults = []
                    focused = nil
                    Task { await buildRoute(to: item) }
                }
            }

            if app.route != nil { departurePicker }
            if let err = app.routeError { errorLabel(err) }
        }
        .animation(.easeInOut(duration: 0.18), value: fromResults.count)
        .animation(.easeInOut(duration: 0.18), value: toResults.count)
        .animation(.easeInOut(duration: 0.18), value: app.route != nil)
    }

    // MARK: - Search card

    private var searchCard: some View {
        HStack(alignment: .center, spacing: 12) {
            pinColumn
            VStack(spacing: 6) {
                fromField
                Divider().background(Color.white.opacity(0.12))
                toField
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.58))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
    }

    private var pinColumn: some View {
        VStack(spacing: 0) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.blue)
                .frame(height: 38)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                        .frame(width: 2, height: 5)
                }
            }
            Image(systemName: "mappin.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.red)
                .frame(height: 38)
        }
    }

    private var fromField: some View {
        HStack(spacing: 6) {
            TextField("From", text: $fromText)
                .focused($focused, equals: .from)
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .autocorrectionDisabled()
                .onSubmit { Task { await submitFrom() } }
                .onChange(of: fromText) { _, new in
                    guard new != "My Location", new.count > 2 else { fromResults = []; return }
                    Task { await fetchFrom() }
                }
            if !fromText.isEmpty && fromText != "My Location" {
                Button {
                    fromText = "My Location"
                    fromCoordinate = nil
                    fromResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                        .font(.system(size: 14))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(focused == .from ? 0.13 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var toField: some View {
        HStack(spacing: 6) {
            TextField("Where to?", text: $toText)
                .focused($focused, equals: .to)
                .font(.subheadline)
                .foregroundStyle(.white)
                .tint(.white)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { Task { await submitTo() } }
                .onChange(of: toText) { _, new in
                    guard new.count > 2 else { toResults = []; return }
                    Task { await fetchTo() }
                }
            if app.isRouting {
                ProgressView().scaleEffect(0.7).tint(.white.opacity(0.6))
            } else if !toText.isEmpty {
                Button {
                    toText = ""
                    toResults = []
                    app.clearRoute()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.35))
                        .font(.system(size: 14))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(focused == .to ? 0.13 : 0.07))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Suggestions

    private func suggestionList(_ items: [MKMapItem], onSelect: @escaping (MKMapItem) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(5).enumerated()), id: \.offset) { idx, item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "mappin")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name ?? "Unknown")
                                .font(.subheadline)
                                .foregroundStyle(.white)
                            if let addr = item.placemark.title {
                                Text(addr)
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.6))
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                if idx < min(items.count, 5) - 1 {
                    Divider().background(Color.white.opacity(0.12))
                }
            }
        }
        .background(Color.black.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    // MARK: - Departure / Error

    @State private var customHours: Int = 4
    @State private var showCustom: Bool = false

    private var departurePicker: some View {
        VStack(spacing: 6) {
            // Preset chips
            HStack(spacing: 8) {
                ForEach([(0.0, "Now"), (3600.0, "+1 h"), (10800.0, "+3 h")], id: \.1) { offset, label in
                    Button {
                        showCustom = false
                        app.departureOffset = offset
                        app.rescoreRoute()
                    } label: {
                        Text(label)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(app.departureOffset == offset && !showCustom
                                        ? Color.white.opacity(0.25)
                                        : Color.white.opacity(0.08))
                            .foregroundStyle(.white)
                            .clipShape(Capsule())
                    }
                }

                // Custom chip
                Button {
                    showCustom.toggle()
                    if showCustom {
                        app.departureOffset = TimeInterval(customHours * 3600)
                        app.rescoreRoute()
                    }
                } label: {
                    Text(showCustom ? "+\(customHours) h" : "Custom")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(showCustom
                                    ? Color.white.opacity(0.25)
                                    : Color.white.opacity(0.08))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)

            // Custom hour stepper
            if showCustom {
                HStack(spacing: 12) {
                    Text("Depart in")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                    Stepper("\(customHours) h", value: $customHours, in: 1...24)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .onChange(of: customHours) { _, h in
                            app.departureOffset = TimeInterval(h * 3600)
                            app.rescoreRoute()
                        }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: showCustom)
    }

    private func errorLabel(_ msg: String) -> some View {
        Label(msg, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.red)
            .padding(.horizontal, 16).padding(.bottom, 6)
    }

    // MARK: - Network

    private func fetchFrom() async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = fromText
        if let info = app.engine.gridInfo(for: app.selectedStateName) { req.region = info.region }
        fromResults = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
    }

    private func fetchTo() async {
        let req = MKLocalSearch.Request()
        req.naturalLanguageQuery = toText
        if let info = app.engine.gridInfo(for: app.selectedStateName) { req.region = info.region }
        toResults = (try? await MKLocalSearch(request: req).start())?.mapItems ?? []
    }

    private func submitFrom() async {
        await fetchFrom()
        if let first = fromResults.first {
            fromText = first.name ?? ""
            fromCoordinate = first.placemark.location?.coordinate
            fromResults = []
            focused = .to
        }
    }

    private func submitTo() async {
        await fetchTo()
        if let first = toResults.first { await buildRoute(to: first) }
    }

    private func buildRoute(to item: MKMapItem) async {
        guard let dest = item.placemark.location?.coordinate else { return }
        let origin: CLLocationCoordinate2D
        if let fc = fromCoordinate {
            origin = fc
        } else if let info = app.engine.gridInfo(for: app.selectedStateName) {
            origin = info.centerCoordinate
        } else {
            origin = CLLocationCoordinate2D(latitude: 41.59, longitude: -93.62)
        }
        await app.buildRoute(to: dest, from: origin)
    }
}
