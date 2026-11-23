import SwiftUI

/// Settings › Developer › Remote debug log: the endpoint URL and token for RemoteLog (both empty = off).
struct RemoteLogSection: View {
    @State private var url = RemoteLogConfig.load().url
    @State private var token = RemoteLogConfig.load().token

    private var config: RemoteLogConfig { RemoteLogConfig(url: url, token: token) }

    var body: some View {
        Section {
            TextField("Endpoint URL", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Token", text: $token)
            HStack {
                Text("Status")
                Spacer()
                Text(config.endpoint == nil ? "Off" : "On").foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote debug log")
        } footer: {
            Text("For debugging your own iPhone: when both are set, the app checks this server about every 30 seconds while it is open or a run is going and, when asked, uploads the end of its text debug log, with keys and tokens removed. Never screenshots. Leave empty to turn it off. This token can't send the phone tasks: Remote tasks below has its own switch and token.")
        }
        .onValueChange(of: config) { config.save() }
    }
}

/// Settings › Developer › Remote tasks (fork): its own switch (off by default), URL and token for RemoteTasks.
struct RemoteTasksSection: View {
    @State private var enabled = RemoteTaskConfig.load().enabled
    @State private var url = RemoteTaskConfig.load().url
    @State private var token = RemoteTaskConfig.load().token

    private var config: RemoteTaskConfig { RemoteTaskConfig(enabled: enabled, url: url, token: token) }

    var body: some View {
        Section {
            Toggle("Allow remote tasks", isOn: $enabled)
            TextField("Task server URL", text: $url)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Task token", text: $token)
            HStack {
                Text("Status")
                Spacer()
                Text(config.endpoint == nil ? "Off" : "On").foregroundStyle(.secondary)
            }
        } header: {
            Text("Remote tasks")
        } footer: {
            Text("Lets whoever holds this token control this iPhone. When on, the app asks this server for a task about every 15 seconds while nothing runs, runs it unattended, and sends the run's final answer back as written (it may include what was on screen). You get a notification for each task. Off by default; turn it off to stop.")
        }
        .onValueChange(of: config) { config.save() }
    }
}
