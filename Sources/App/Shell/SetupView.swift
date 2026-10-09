// SetupView.swift: what to do when this Mac is missing a tool.

import AppKit
import Engine
import SwiftUI

/// What installing or updating is doing right now, or how it ended.
struct ProvisionLine: View {
    @ObservedObject private var tools = AppModel.shared.tools
    @Environment(\.palette) private var p

    var body: some View {
        switch tools.provision {
        case .idle:
            EmptyView()
        case .working(let text, let fraction):
            HStack(spacing: 10) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(text).font(p.font(13)).foregroundColor(p.subtext)
            }
        case .done(let text):
            Text(text).font(p.font(13)).foregroundColor(p.good).fixedSize(horizontal: false, vertical: true)
        case .failed(let text):
            Text(text).font(p.font(13)).foregroundColor(p.bad).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// The first thing a Mac without the tools shows: the artwork and a welcome
/// on one side, what is missing and the ways to get it on the other. It has
/// the whole window; the sidebar appears once the tools are there.
struct SetupView: View {
    @ObservedObject private var tools = AppModel.shared.tools
    @Environment(\.palette) private var p

    private func toolRow(_ status: ToolStatus) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.tool.rawValue)
                    .font(p.font(14, .semibold))
                    .foregroundColor(p.text)
                Text(status.tool.purpose)
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Label(status.found ? "Found" : "Missing",
                  systemImage: status.found ? "checkmark" : "exclamationmark.triangle.fill")
                .font(p.font(13, .semibold))
                .foregroundColor(status.found ? p.good : p.warn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            BrandArt(height: 220)
            Text(Messages.tourWelcome)
                .font(p.font(26, .bold))
                .foregroundColor(p.text)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text("Save video and audio from YouTube and other sites, and convert what you have. A few free programs need to be in place first.")
                .font(p.font(13))
                .foregroundColor(p.subtext)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 320)
        .frame(maxHeight: .infinity)
        .background(p.mantle.ignoresSafeArea())
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("One more step before \(Engine.productName) can work")
                .font(p.font(20, .semibold))
                .foregroundColor(p.text)
                .padding(.horizontal, 14)
                .accessibilityAddTraits(.isHeader)
            Text("\(Engine.productName) uses a few free programs to download and convert videos. This Mac is missing some of them.")
                .font(p.font(13))
                .foregroundColor(p.subtext)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
            Grouped(title: "What \(Engine.productName) needs") {
                ForEach(Array(tools.statuses.enumerated()), id: \.element.tool) { pair in
                    VStack(spacing: 0) {
                        if pair.offset > 0 { RowDivider() }
                        toolRow(pair.element)
                    }
                }
            }
            Card(title: "The easy way") {
                Text("\(Engine.productName) can download the free programs itself and keep its own copies, so you never need Terminal. Each file is checked against a fixed fingerprint before it is used, and nothing is installed if it does not match. This takes about a minute.")
                    .font(p.font(13))
                    .foregroundColor(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button {
                        tools.installMissingTools()
                    } label: {
                        Label("Install the Programs", systemImage: "bolt.fill")
                    }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(tools.isBusy)
                    ProvisionLine()
                }
            }
            Card(title: "Or use Homebrew") {
                Text("Prefer to manage them yourself? Use Homebrew instead.\n\n1. Press Copy the command below.\n2. Open Terminal (the button below opens it) and paste with Cmd-V, then press Return.\n3. If your Mac asks for its password, type it. Nothing shows as you type, and that is normal.\n4. If it offers to install Apple's command line tools, say yes. The whole thing can take a few minutes.\n5. When it finishes, come back here and press Check again.")
                    .font(p.font(13))
                    .foregroundColor(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ToolRegistry.homebrewSetupCommand)
                    .font(p.mono(11))
                    .foregroundColor(p.subtext)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fieldChrome()
                HStack(spacing: 8) {
                    Button("Copy the command") { Opener.copy(ToolRegistry.homebrewSetupCommand) }
                        .buttonStyle(PillButtonStyle())
                    Button("Open Terminal") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    }
                    .buttonStyle(PillButtonStyle())
                    Button("Check again") { tools.refresh() }
                        .buttonStyle(PillButtonStyle())
                }
                Text("The command installs Homebrew, a well-known installer for free programs, if this Mac does not have it, and then installs the programs from it. \(Engine.productName) never runs it for you.")
                    .font(p.font(12))
                    .foregroundColor(p.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Card(title: "Already have them somewhere else?") {
                Text("If the programs are installed in another place, point \(Engine.productName) at them in Settings, under Tools.")
                    .font(p.font(13))
                    .foregroundColor(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings…") { SettingsWindow.shared.show(.tools) }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            welcome
            Rectangle().fill(p.separator).frame(width: 1).accessibilityHidden(true)
            ScrollView {
                steps
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(p.base)
    }
}
