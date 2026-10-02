import MapKit
import SwiftUI

/// Root screen (A2.1): full-screen map with chips, banner, settings, right rail,
/// pill player, compact card, feed sheet and the Detail push.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    mapLayer
                    overlays
                }
                .onAppear { model.mapSize = geo.size }
                .onChange(of: geo.size) { _, size in model.mapSize = size }
            }
            .overlay(alignment: .bottom) {
                if let inc = model.selectedIncident {
                    IncidentCard(incident: inc)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.spring(duration: 0.35), value: model.selectedIncidentId)
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Int.self) { id in
                IncidentDetailView(incidentId: id)
            }
            .sheet(isPresented: $model.showFeed) {
                FeedSheet()
            }
            .sheet(isPresented: $model.showSettings) {
                SettingsView()
            }
        }
    }

    // MARK: Map

    private var mapLayer: some View {
        @Bindable var model = model
        return Map(position: $model.cameraPosition, interactionModes: .all) {
            UserAnnotation()
            ForEach(model.visibleIncidents) { inc in
                Annotation("", coordinate: inc.coordinate, anchor: .center) {
                    IncidentPin(
                        incident: inc,
                        now: model.now,
                        fadeWindow: model.settings.fadeWindow,
                        enlarged: inc.id == model.focusedIncidentId
                    )
                    .onTapGesture { model.select(inc) }
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControlVisibility(.hidden)
        .onMapCameraChange(frequency: .onEnd) { ctx in model.visibleRegion = ctx.region }
        .onTapGesture { model.select(nil) }
        .ignoresSafeArea()
    }

    // MARK: Overlays

    private var overlays: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    AgencyChips(enabled: model.enabledAgencies) { model.toggle($0) }
                    if let inc = model.bannerIncident, model.selectedIncidentId == nil {
                        LatestBanner(
                            incident: inc,
                            distance: model.distanceText(to: inc),
                            now: model.now,
                            onTap: { model.openDetail(inc.id) },
                            onDismiss: { model.dismissBanner() }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(inc.id)
                    }
                }
                Spacer(minLength: 0)
                settingsButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .animation(.spring(duration: 0.4), value: model.bannerIncident?.id)

            Spacer()

            if model.selectedIncidentId == nil {
                HStack(alignment: .bottom) {
                    connectionBadge
                    Spacer()
                    RightRail(
                        unread: model.unreadCount,
                        onLocate: { model.locateMe() },
                        onFeed: { model.showFeed = true }
                    )
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                PillPlayer()
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
        }
    }

    private var settingsButton: some View {
        Button { model.showSettings = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                .floatingSurface(radius: Theme.touchTarget / 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    @ViewBuilder
    private var connectionBadge: some View {
        if !model.connection.isLive {
            Text(model.connection.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .floatingSurface(radius: 14)
        }
    }
}

#Preview {
    HomeView().environment(Fixtures.model())
}
