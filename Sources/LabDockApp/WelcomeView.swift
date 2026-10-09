import LabDockCore
import SwiftUI
import VimClient

/// What the detail shows when no VM is selected: LabDC's welcome (the date, a greeting by the
/// Mac's clock with its picture rising behind the last letters), then the hosts in a sentence
/// each, and the way in (owner, 3 Oct 2026: "the first page was too bare; bring LabDC's Welcome").
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @State private var period = GreetingPeriod()
    @State private var playID = 0
    /// The picture plays for a few seconds and fades (LabDC's default), so the welcome page
    /// costs nothing while it just sits there (owner asked about RAM/CPU, 3 Oct 2026).
    @State private var showArt = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(Theme.detail)
                    .foregroundStyle(Theme.muted)
                greeting
                    .padding(.top, 6)
                summary
                    .padding(.top, 44)
                hostRows
                    .padding(.top, 28)
            }
            .padding(Theme.pageInsets)
            .padding(.top, 18)   // room above the greeting for its picture
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollClipDisabled()
        .background(Theme.background)
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            let now = GreetingPeriod()
            if now != period {
                period = now
                playID += 1
                showArt = true
            }
        }
    }

    /// The 52 pt light greeting with the picture behind its last letters, as on LabDC's Overview.
    private var greeting: some View {
        let k = Theme.greetingSize / 48
        return Text(period.greeting)
            .font(Theme.greeting)
            .tracking(-1)
            .foregroundStyle(Theme.ink)
            .fixedSize()
            .background(alignment: .bottomTrailing) {
                if showArt {
                    let bleed = GreetingArtwork.bleed
                    GreetingArtView(scene: .greeting(period, hold: 5), playID: playID, active: true,
                                    onFinished: { showArt = false })
                        .frame(width: 220 * k + 2 * bleed, height: 156 * k + 2 * bleed)
                        .offset(x: 86 * k + bleed, y: -2 * k + bleed)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onAppear { showArt = true; playID += 1 }
            .accessibilityAddTraits(.isHeader)
    }

    /// "2 hosts · 45 virtual machines, 7 running." with the running count in green.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.hosts.isEmpty {
                Text("No ESXi hosts yet. Use Add host… at the bottom of the sidebar; its virtual machines then appear there.")
                    .font(Theme.subtitle)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                (Text(hostsWord) + Text(" · ") + Text(vmsWord) + runningText + Text("."))
                    .font(Theme.subtitle)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Pick a virtual machine in the sidebar. Power, snapshots, files, commands and the console are one tab each.")
                    .font(Theme.body)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let storeError = model.storeError {
                Text(storeError).font(Theme.detail).foregroundStyle(Theme.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var hostsWord: String { model.hosts.count == 1 ? "1 host" : "\(model.hosts.count) hosts" }
    private var vmsWord: String { model.totalVMs == 1 ? "1 virtual machine" : "\(model.totalVMs) virtual machines" }
    private var runningText: Text {
        guard model.runningVMs > 0 else { return Text("") }
        return Text(", ") + Text("\(model.runningVMs) running").foregroundStyle(Theme.on)
    }

    /// One line per host: the address, what it is, how it's doing.
    private var hostRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.hosts) { host in
                HostLine(host: host)
            }
        }
    }
}

/// A host on the welcome page: address in ink, then its state as words.
private struct HostLine: View {
    let host: HostModel

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(host.address)
                    .font(Theme.emphasis)
                    .foregroundStyle(Theme.ink)
                Text(stateWord)
                    .font(Theme.caption)
                    .foregroundStyle(stateColor)
            }
            Text(detail)
                .font(Theme.detail)
                .foregroundStyle(detailColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    private var stateWord: String {
        switch host.phase {
        case .connecting: "connecting…"
        case .connected: "connected"
        case .failed: "unreachable"
        case .needsTrust: "certificate changed"
        }
    }

    private var stateColor: Color {
        switch host.phase {
        case .connecting: Theme.faint
        case .connected: Theme.on
        case .failed, .needsTrust: Theme.off
        }
    }

    private var detail: String {
        switch host.phase {
        case .connected, .connecting: host.subtitle
        case .failed(let why): [why, host.lastSeenLine].compactMap { $0 }.joined(separator: " · ")
        case .needsTrust: host.problemLine ?? ""
        }
    }

    private var detailColor: Color {
        if case .connected = host.phase { return Theme.muted }
        if case .connecting = host.phase { return Theme.muted }
        return Theme.attention
    }
}
