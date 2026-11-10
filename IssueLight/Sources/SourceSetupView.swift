import SwiftUI
import UniformTypeIdentifiers

struct SourceSetupView: View {
    @ObservedObject var model: SourceSetupModel
    @State private var importURL: URL?
    @State private var isChoosingIdentity = false
    @State private var isImportingIdentity = false
    @State private var isConfirmingDeletion = false
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("Typ", value: "Icinga 2")
                    TextField("Name", text: $model.name, prompt: Text("Produktion"))
                    TextField("Server", text: $model.endpoint, prompt: Text("https://icinga.example:5665"))
                        .textContentType(.URL)
                } header: {
                    Text("Quelle")
                } footer: {
                    Text("IssueLight prüft Hosts und Services über die echte Icinga-2-API.")
                }

                Section("Authentifizierung") {
                    Picker("Methode", selection: $model.authenticationChoice) {
                        ForEach(SourceSetupModel.AuthenticationChoice.allCases) { choice in
                            Text(choice.rawValue).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.authenticationChoice == .basic {
                        TextField("Benutzername", text: $model.username)
                            .textContentType(.username)
                        SecureField("Passwort", text: $model.password)
                            .textContentType(.password)
                        Text("Das Passwort wird ausschließlich im macOS-Schlüsselbund gespeichert.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        if let identityLoadError = model.identityLoadError {
                            Label(identityLoadError, systemImage: "exclamationmark.circle")
                                .foregroundStyle(.red)
                        }
                        Picker("Identität", selection: $model.selectedIdentityID) {
                            Text("Zertifikat auswählen …").tag("")
                            ForEach(model.identities) { identity in
                                Text(identity.displayName).tag(identity.id)
                            }
                        }
                        Button("PKCS#12 importieren …") {
                            isChoosingIdentity = true
                        }
                        .fileImporter(
                            isPresented: $isChoosingIdentity,
                            allowedContentTypes: [UTType(filenameExtension: "p12") ?? .data, UTType(filenameExtension: "pfx") ?? .data],
                            allowsMultipleSelection: false
                        ) { result in
                            if case .success(let urls) = result, let url = urls.first {
                                importURL = url
                                isImportingIdentity = true
                            }
                        }
                    }
                }

                Section {
                    Toggle("Serverzertifikat prüfen", isOn: $model.verifiesServerCertificate)
                    if !model.verifiesServerCertificate {
                        Label {
                            Text("Unsicher. Identität und Serverdaten können abgefangen oder verändert werden. Diese Ausnahme gilt nur für diese Quelle.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("TLS")
                } footer: {
                    Text("Die Prüfung ist standardmäßig aktiv. Selbstsignierte Homelab-Systeme können sie bewusst deaktivieren.")
                }

                Section {
                    activityView
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if model.hasConfiguredSource {
                    Button("Quelle entfernen", role: .destructive) {
                        isConfirmingDeletion = true
                    }
                    .disabled(isWorking)
                }
                Spacer()
                if model.isTestingConnection {
                    Button("Abbrechen", role: .cancel) {
                        connectionTask?.cancel()
                    }
                } else {
                    Button("Verbindung testen") {
                        connectionTask = Task { await model.testConnection() }
                    }
                    .disabled(isWorking)
                }

                Button("Speichern") {
                    Task { await model.save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isWorking)
            }
            .padding(16)
            .background(.bar)
        }
        .frame(minWidth: 560, minHeight: 560)
        .task { await model.load() }
        .onDisappear { connectionTask?.cancel() }
        .sheet(isPresented: $isImportingIdentity) {
            if let importURL {
                IdentityImportView(fileURL: importURL, model: model, isPresented: $isImportingIdentity)
            }
        }
        .confirmationDialog(
            "Quelle wirklich entfernen?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Quelle entfernen", role: .destructive) {
                Task { await model.deleteSource() }
            }
        } message: {
            Text(model.deletionMessage)
        }
    }

    @ViewBuilder
    private var activityView: some View {
        switch model.activity {
        case .idle:
            Text("Konfiguration eingeben, Verbindung prüfen und anschließend speichern.")
                .foregroundStyle(.secondary)
        case .working(let message):
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text(message)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }

    private var isWorking: Bool {
        if case .working = model.activity { return true }
        return false
    }
}

private struct IdentityImportView: View {
    let fileURL: URL
    @ObservedObject var model: SourceSetupModel
    @Binding var isPresented: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Client-Zertifikat importieren")
                .font(.title2.weight(.semibold))
            Text(fileURL.lastPathComponent)
                .foregroundStyle(.secondary)
            SecureField("PKCS#12-Passwort", text: $password)
                .textContentType(.password)
            Text("Das Importpasswort wird nicht gespeichert.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen") { isPresented = false }
                Button("Importieren") {
                    Task {
                        if await model.importIdentity(at: fileURL, password: password) {
                            isPresented = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
