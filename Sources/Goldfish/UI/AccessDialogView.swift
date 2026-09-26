import SwiftUI
import AppKit

struct AccessDialogView: View {
    @EnvironmentObject var model: RecoveryModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.68)
                    .ignoresSafeArea()
                    .onTapGesture { model.permissionHelp = false }

                VStack(spacing: 0) {
                    accessDialogHeader
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            accessErrorDetails
                            accessExplanation
                            accessSteps
                            readOnlyNotice
                        }
                        .padding(24)
                    }
                    .scrollIndicators(.visible)
                    accessDialogFooter
                }
                .frame(width: min(600, geometry.size.width - 40))
                .frame(maxHeight: min(660, geometry.size.height - 48))
                .background(Color.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.6), radius: 32, x: 0, y: 18)
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }

    private var accessDialogHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.amber)
                .frame(width: 40, height: 40)
                .background(Color.amber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.amber.opacity(0.25), lineWidth: 1))
            VStack(alignment: .leading, spacing: 4) {
                Text("SD card access needed")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(Color.ink)
                Text("Goldfish found your card, but macOS is blocking raw read access to the device. Nothing on the card was changed.")
                    .font(.system(size: 12)).lineSpacing(3).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button { model.permissionHelp = false } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.muted)
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Close access dialog")
        }
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 18)
    }

    private var accessErrorDetails: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.coral)
                Text("Couldn’t open device for reading")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.coral)
                Spacer()
                Button {
                    let details = model.diagnostic.isEmpty ? "Couldn’t open device for reading: \(model.selected?.path ?? "no device selected")" : model.diagnostic
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details, forType: .string)
                    model.message = "Access error details copied"
                } label: {
                    Label("Copy details", systemImage: "doc.on.doc").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.coral.opacity(0.07))
            .overlay(alignment: .bottom) { Rectangle().fill(Color.coral.opacity(0.15)).frame(height: 1) }

            VStack(spacing: 7) {
                accessDetailRow("Device", model.selected?.path ?? "No device selected", monospaced: true)
                accessDetailRow("Requested", "Read-only access")
                accessDetailRow("Blocked by", "macOS raw-device permissions")
                if !model.diagnostic.isEmpty {
                    Text(model.diagnostic)
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(Color.muted)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 9))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.coral.opacity(0.2), lineWidth: 1))
    }

    private func accessDetailRow(_ title: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.system(size: 9)).foregroundStyle(Color.muted).frame(width: 72, alignment: .leading)
            Text(value).font(monospaced ? .system(size: 9, design: .monospaced) : .system(size: 9, weight: .medium))
                .foregroundStyle(Color.ink).textSelection(.enabled).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessExplanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Why Full Disk Access isn’t enough")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.ink)
            Text("Full Disk Access covers files on your Mac. Reading an SD card’s raw device node (such as /dev/disk*) is a separate permission that may require administrator approval.")
                .font(.system(size: 11)).lineSpacing(3).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessSteps: some View {
        VStack(alignment: .leading, spacing: 12) {
            accessStep(1, "Authorize device access", "Approve the macOS administrator prompt. Goldfish will verify read access afterward.")
            accessStep(2, "Try the scan again", "Once access is available, start the read-only scan again from this window.")
            accessStep(3, "If access still isn’t available", "Sign out and back in so macOS can apply the updated group membership, then reopen Goldfish.")
        }
    }

    private func accessStep(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(Color.ink)
                .frame(width: 20, height: 20).background(Color.raised, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink)
                Text(detail).font(.system(size: 9)).lineSpacing(2).foregroundStyle(Color.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readOnlyNotice: some View {
        Label("Read-only: Goldfish only opens the card for reading and never writes to it.", systemImage: "checkmark.shield.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.mint)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.mint.opacity(0.16), lineWidth: 1))
    }

    private var accessDialogFooter: some View {
        HStack(spacing: 10) {
            Button { model.openFullDiskAccessSettings() } label: {
                Label("Open Full Disk Access", systemImage: "gearshape")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.muted)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            Button {
                model.permissionHelp = false
                model.start()
            } label: {
                Label("Try scan again", systemImage: "arrow.clockwise")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.ink)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.raised, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.border, lineWidth: 1))
            }
            .buttonStyle(.plain).disabled(model.selected == nil)
            Button { model.requestDeviceReadAccess() } label: {
                Label("Authorize device access", systemImage: "lock.open")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.canvas)
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Color.mint, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain).disabled(model.selected == nil || model.isPrivileged)
            .help(model.isPrivileged ? "Device access is already running with administrator privileges" : "Request read access to the selected device")
        }
        .padding(.horizontal, 24).padding(.vertical, 15)
        .background(Color.canvas)
        .overlay(alignment: .top) { Rectangle().fill(Color.border).frame(height: 1) }
    }
}
