import SwiftUI

struct LichessBotView: View {
    @StateObject private var bot = LichessBotService()
    @State private var token = ""
    @State private var showToken = false

    var body: some View {
        Form {
            Section("Lichess bot account") {
                Text("Use a dedicated bot-account token with bot:play permission. Never share it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Group {
                    if showToken {
                        TextField("Lichess API token", text: $token)
                    } else {
                        SecureField("Lichess API token", text: $token)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

                Toggle("Show token", isOn: $showToken)

                Button("Start bot") {
                    if token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        bot.startUsingSavedToken()
                    } else {
                        bot.start(token: token)
                    }
                }
                .buttonStyle(.borderedProminent)

                Button("Stop bot", role: .destructive) {
                    bot.stop()
                }

                Button("Remove saved token", role: .destructive) {
                    bot.removeSavedToken()
                    token = ""
                }
            }

            Section("Status") {
                Text(bot.status)
            }

            Section("Activity log") {
                ScrollView {
                    Text(bot.log.isEmpty ? "No activity yet." : bot.log)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 160, maxHeight: 300)
            }

            Section {
                Text("Keep the app open while playing. iOS may suspend network activity in the background. Standard-chess challenges are currently accepted automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Lichess Bot")
        .navigationBarTitleDisplayMode(.inline)
    }
}
