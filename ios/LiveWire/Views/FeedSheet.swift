import SwiftUI

/// Feed sheet (A2.3). Opens at half with the map still usable; search, Mapped-only
/// and the "↑ Now" button are only shown at the full detent.
struct FeedSheet: View {
    @Environment(AppModel.self) private var model

    @State private var detent: PresentationDetent = .fraction(0.5)
    @State private var search = ""
    @State private var mappedOnly = false
    /// Snapshot shown while the user is scrolled away from the top; new rows accumulate.
    @State private var frozen: [Transmission]?
    @State private var visibleIds: Set<Int> = []
    @State private var scrollTopToken = 0

    private var isFull: Bool { detent == .large }

    /// Live rows: agency filter, then (full detent only) search and Mapped-only.
    private var liveRows: [Transmission] {
        model.transmissions.filter { t in
            guard model.passesFilter(t.agency) else { return false }
            if isFull {
                if mappedOnly && !t.isMapped { return false }
                if !t.matches(search: search) { return false }
            }
            return true
        }
    }

    private var rows: [Transmission] { frozen ?? liveRows }

    /// New rows that arrived while scrolled away.
    private var pendingCount: Int {
        guard let frozen, let top = frozen.first?.id else { return 0 }
        return liveRows.reduce(0) { $0 + ($1.id > top ? 1 : 0) }
    }

    private var atTop: Bool {
        let ids = rows.prefix(2).map(\.id)
        return ids.isEmpty || ids.contains { visibleIds.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            if isFull {
                controls
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider().overlay(Theme.hairline)
            list
        }
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            if isFull && !atTop {
                nowButton.padding(.bottom, 18)
            }
        }
        .presentationDetents([.fraction(0.5), .large], selection: $detent)
        .presentationBackgroundInteraction(.enabled(upThrough: .fraction(0.5)))
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.panel)
        .onChange(of: model.transmissions.first?.id) {
            // At the top: let new rows animate in. Scrolled away: freeze and count.
            if atTop {
                frozen = nil
            } else if frozen == nil {
                frozen = liveRows
            }
        }
        .onChange(of: atTop) { _, top in
            if top { withAnimation(.easeInOut(duration: 0.25)) { frozen = nil } }
        }
        .onChange(of: search) { frozen = nil }
        .onChange(of: mappedOnly) { frozen = nil }
        .onChange(of: detent) { frozen = nil }
        .onAppear { model.markFeedSeen() }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 10) {
            Text("Feed")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(Theme.text)
            if model.connection.isLive { LiveDot() }
            Text("\(model.lastHourCount) in last hour")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Spacer()
            if !model.connection.isLive {
                Text(model.connection.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search transcript, summary, address, units", text: $search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(size: 15))
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.muted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.muted.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.cell, style: .continuous))

            Toggle(isOn: $mappedOnly) {
                Text("Mapped only")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .tint(Theme.police)
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 1).id("feed-top")
                    ForEach(rows) { tx in
                        FeedRow(
                            tx: tx,
                            now: model.now,
                            highlighted: model.highlightedTransmissionId == tx.id,
                            onTap: {
                                model.focus(on: tx)
                                detent = .fraction(0.5)
                            },
                            onPlay: { model.audio.replay(tx) }
                        )
                        .onAppear { visibleIds.insert(tx.id) }
                        .onDisappear { visibleIds.remove(tx.id) }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        Divider().overlay(Theme.hairline).padding(.leading, 16)
                    }
                    if rows.isEmpty {
                        Text(search.isEmpty ? "Nothing heard yet" : "No matches")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.muted)
                            .padding(.top, 40)
                    }
                }
                .animation(frozen == nil ? Animation.easeInOut(duration: 0.25) : nil, value: rows.first?.id)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: scrollTopToken) {
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo("feed-top", anchor: .top) }
            }
        }
    }

    private var nowButton: some View {
        Button {
            frozen = nil
            scrollTopToken += 1
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                Text(pendingCount > 0 ? "Now · \(pendingCount) new" : "Now")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.ground)
            .padding(.horizontal, 16)
            .frame(height: Theme.touchTarget)
            .background(Theme.text, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        }
        .buttonStyle(.plain)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityLabel(pendingCount > 0 ? "Scroll to now, \(pendingCount) new" : "Scroll to now")
    }
}

/// One feed row: agency dot; "11:52 AM · 2m ago" (+ pin glyph if mapped); summary
/// (mapped rows only); transcript; 32 pt play button.
struct FeedRow: View {
    var tx: Transmission
    var now: Date
    var highlighted: Bool
    var onTap: () -> Void
    var onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AgencyDot(agency: tx.agency)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(Format.timeAndAgo(tx.occurredAt, now: now))
                    if tx.isMapped {
                        Image(systemName: "mappin.circle.fill").font(.system(size: 11))
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                if tx.isMapped, let headline = tx.headline {
                    Text(headline)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                }
                Text(tx.transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onPlay) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(Theme.text.opacity(0.12), in: Circle())
                    .frame(width: Theme.touchTarget, height: Theme.touchTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tx.audioFile == nil)
            .accessibilityLabel("Play clip")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(highlighted ? tx.agency.color.opacity(0.12) : Color.clear)
        .animation(.easeInOut(duration: 0.2), value: highlighted)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

#Preview {
    Color.clear
        .sheet(isPresented: .constant(true)) { FeedSheet() }
        .environment(Fixtures.model())
}
