import SwiftUI

struct LicenseSettingsView: View {
    @ObservedObject private var licenseViewModel = LicenseViewModel.shared
    @State private var licenseKeyDraft = ""
    @State private var showingDeactivateConfirmation = false

    private let licensePortalURL = URL(string: "https://polar.sh/beingpax/portal/request")!

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if licenseViewModel.hasVerifiedLicense {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.tint)
                            .imageScale(.large)
                    } else {
                        Button("Buy License") {
                            licenseViewModel.openPurchaseLink()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } label: {
                    Text("VoiceInk Pro")
                        .font(.headline)
                    Text(statusSummary)
                }

                if licenseViewModel.hasVerifiedLicense {
                    LabeledContent("License Key") {
                        Text(licenseViewModel.licenseKey)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }

                    LabeledContent("Manage License") {
                        HStack {
                            Link("Open Portal", destination: licensePortalURL)
                            Button("Deactivate…", role: .destructive) {
                                showingDeactivateConfirmation = true
                            }
                            .disabled(licenseViewModel.isDeactivating)
                        }
                    }
                }
            } footer: {
                validationMessage
            }

            if !licenseViewModel.hasVerifiedLicense {
                Section {
                    LabeledContent {
                        HStack {
                            TextField("License Key", text: $licenseKeyDraft)
                                .labelsHidden()
                                .font(.body.monospaced())
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(activate)

                            Button("Activate", action: activate)
                                .disabled(
                                    licenseViewModel.isValidating
                                        || licenseKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("License Key")
                            if licenseViewModel.isValidating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                } header: {
                    Text("Have a License Key?")
                } footer: {
                    if licenseViewModel.activationsLimit > 0 {
                        Text("A license can be active on \(licenseViewModel.activationsLimit) Macs at a time.")
                    }
                }
            }

            Section("Resources") {
                resourceLink("Documentation", url: "https://tryvoiceink.com/docs")
                resourceLink("Recommended Models", url: "https://tryvoiceink.com/recommended-models")
                resourceLink("Videos & Guides", url: "https://www.youtube.com/@tryvoiceink/videos")
                resourceLink("Release Notes", url: "https://github.com/Beingpax/VoiceInk/releases")
                resourceLink("Affiliate Program", url: "https://tryvoiceink.com/affiliate")
                if !licenseViewModel.hasVerifiedLicense {
                    Link("Lost License Key", destination: licensePortalURL)
                }
                resourceLink("Discord", url: "https://discord.gg/xryDy57nYD")
                Button("Email Support") {
                    EmailSupport.openSupportEmail()
                }
                .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Deactivate License?", isPresented: $showingDeactivateConfirmation) {
            Button("Deactivate License", role: .destructive) {
                Task { await licenseViewModel.deactivateLicense() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deactivates VoiceInk on this Mac and frees a device on your license.")
        }
        .onChange(of: licenseViewModel.hasVerifiedLicense) { _, _ in
            licenseKeyDraft = ""
        }
    }

    @ViewBuilder
    private var validationMessage: some View {
        if let message = licenseViewModel.validationMessage {
            Label(
                message,
                systemImage: licenseViewModel.validationSuccess
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
            )
            .foregroundStyle(licenseViewModel.validationSuccess ? Color.green : Color.orange)
        }
    }

    private var statusSummary: String {
        switch licenseViewModel.licenseState {
        case .unlicensed:
            return String(localized: "License required")
        case .licensed:
            return String(localized: "Licensed")
        case .trial(let daysRemaining):
            return String(localized: "\(daysRemaining) days left in trial")
        case .trialExpired:
            return String(localized: "Trial ended")
        }
    }

    private func resourceLink(_ title: LocalizedStringKey, url: String) -> some View {
        Link(title, destination: URL(string: url)!)
    }

    private func activate() {
        guard !licenseViewModel.isValidating else { return }
        Task { await licenseViewModel.validateLicense(licenseKeyDraft) }
    }
}
