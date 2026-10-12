import Foundation
import Combine
import Security
import SFEngine

@MainActor
final class LichessBotService: ObservableObject {
    @Published private(set) var status = "Stopped"
    @Published private(set) var log = ""

    private var token = ""
    private var eventTask: Task<Void, Never>?
    private var gameTask: Task<Void, Never>?
    private var engine: SFEngine?

    private var gameID: String?
    private var botColor: String?
    private var currentMoves = ""
    private var searchedMoves: String?
    private var engineReady = false
    private var searching = false
    private var movePending = false

    func start(token suppliedToken: String) {
        let cleanToken = suppliedToken.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !cleanToken.isEmpty else {
            status = "Enter a Lichess bot token"
            return
        }

        stop()
        token = cleanToken

        do {
            try LichessTokenStore.save(cleanToken)
        } catch {
            status = "Could not securely save token"
            return
        }

        status = "Connecting to Lichess..."
        writeLog("Starting Lichess event stream.")

        eventTask = Task {
            await listenForEvents()
        }
    }

    func startUsingSavedToken() {
        do {
            guard let saved = try LichessTokenStore.load(),
                  !saved.isEmpty else {
                status = "No saved token"
                return
            }
            start(token: saved)
        } catch {
            status = "Could not read saved token"
        }
    }

    func removeSavedToken() {
        do {
            try LichessTokenStore.delete()
            status = "Saved token removed"
        } catch {
            status = "Could not remove token"
        }
    }

    func stop() {
        eventTask?.cancel()
        gameTask?.cancel()
        eventTask = nil
        gameTask = nil

        if let engine {
            engine.stop()
        }
        engine = nil

        gameID = nil
        botColor = nil
        currentMoves = ""
        searchedMoves = nil
        engineReady = false
        searching = false
        movePending = false

        status = "Stopped"
    }

    private func writeLog(_ message: String) {
        log += message + "\n"
        if log.count > 12000 {
            log = String(log.suffix(9000))
        }
    }

    private func makeRequest(
        _ path: String,
        method: String = "GET"
    ) -> URLRequest {
        var request = URLRequest(
            url: URL(string: "https://lichess.org" + path)!
        )
        request.httpMethod = method
        request.setValue(
            "Bearer \(token)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            "application/json",
            forHTTPHeaderField: "Accept"
        )
        request.timeoutInterval = 30
        return request
    }

    private func listenForEvents() async {
        while !Task.isCancelled {
            do {
                let request = makeRequest("/api/stream/event")
                let (bytes, response) = try await URLSession.shared.bytes(
                    for: request
                )

                guard let http = response as? HTTPURLResponse,
                      http.statusCode == 200 else {
                    status = "Lichess connection failed"
                    writeLog("Event stream returned an HTTP error.")
                    try await Task.sleep(for: .seconds(5))
                    continue
                }

                status = "Connected — waiting for challenges"
                writeLog("Connected to Lichess.")

                for try await line in bytes.lines {
                    if Task.isCancelled { return }
                    guard !line.isEmpty,
                          let data = line.data(using: .utf8),
                          let object = try? JSONSerialization.jsonObject(
                              with: data
                          ) as? [String: Any] else {
                        continue
                    }

                    handleEvent(object)
                }
            } catch {
                if Task.isCancelled { return }
                status = "Disconnected — reconnecting"
                writeLog("Event stream interrupted.")
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handleEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        if type == "challenge",
           let challenge = event["challenge"] as? [String: Any],
           let id = challenge["id"] as? String {

            let variant = (challenge["variant"] as? [String: Any])?["key"]
                as? String ?? ""

            guard variant == "standard" else {
                writeLog("Ignored non-standard chess challenge.")
                return
            }

            writeLog("Received standard-chess challenge: \(id)")
            Task {
                await acceptChallenge(id)
            }

        } else if type == "gameStart",
                  let game = event["game"] as? [String: Any],
                  let id = game["id"] as? String,
                  let color = game["color"] as? String {

            guard color == "white" || color == "black" else { return }

            gameID = id
            botColor = color
            currentMoves = ""
            searchedMoves = nil
            searching = false
            movePending = false

            status = "Game started as \(color)"
            writeLog("Game started: \(id), playing \(color).")

            startEngine()
            gameTask?.cancel()
            gameTask = Task {
                await streamGame(id: id)
            }

        } else if type == "gameFinish" {
            guard
                let finishedGame = event["game"] as? [String: Any],
                let finishedID = finishedGame["id"] as? String,
                finishedID == gameID
            else {
                return
            }

            writeLog("Game finished.")
            gameTask?.cancel()
            gameTask = nil

            // Tear down the old engine so a late bestmove cannot
            // accidentally be submitted in a subsequent game.
            if let engine {
                engine.stop()
            }
            engine = nil

            gameID = nil
            botColor = nil
            currentMoves = ""
            searchedMoves = nil
            engineReady = false
            searching = false
            movePending = false

            status = "Game finished — waiting for challenges"
        }
    }

    private func acceptChallenge(_ id: String) async {
        do {
            let request = makeRequest(
                "/api/bot/game/accept/\(id)",
                method: "POST"
            )
            let (_, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                writeLog("Could not accept challenge \(id).")
                return
            }

            writeLog("Challenge accepted.")
        } catch {
            writeLog("Challenge acceptance request failed.")
        }
    }

    private func startEngine() {
        guard engine == nil else { return }

        do {
            let networkURL = try StockfishNetworkResource.requiredFileURL()

            engine = SFEngine(
                networkFileURL: networkURL,
                lineHandler: { [weak self] line in
                    Task { @MainActor in
                        self?.handleEngineLine(line)
                    }
                }
            )

            engine?.start()
            engine?.sendCommand("uci")
            writeLog("Starting embedded Stockfish.")
        } catch {
            status = "Stockfish network file unavailable"
            writeLog("Could not load the Stockfish network file.")
        }
    }

    private func handleEngineLine(_ line: String) {
        if line.hasPrefix("info string StockfishEmbedded error") {
            status = "Stockfish startup error"
            writeLog(line)
            return
        }

        if line == "uciok" {
            engine?.sendCommand("isready")
            return
        }

        if line == "readyok" {
            engineReady = true
            writeLog("Stockfish is ready.")
            searchIfNeeded()
            return
        }

        guard line.hasPrefix("bestmove ") else { return }

        searching = false
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return }

        let move = String(parts[1])
        let searchedPosition = searchedMoves

        // Never submit a move calculated for an outdated position.
        guard searchedPosition == currentMoves else {
            searchIfNeeded()
            return
        }

        guard move != "(none)", move != "0000",
              let id = gameID else {
            writeLog("Stockfish returned no legal move.")
            return
        }

        movePending = true
        Task {
            await submitMove(move, game: id, position: searchedPosition ?? "")
        }
    }

    private func streamGame(id: String) async {
        do {
            let request = makeRequest("/api/bot/game/stream/\(id)")
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 else {
                writeLog("Could not open game stream.")
                return
            }

            for try await line in bytes.lines {
                if Task.isCancelled { return }
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(
                          with: data
                      ) as? [String: Any] else {
                    continue
                }

                let type = object["type"] as? String ?? ""
                let state: [String: Any]?

                if type == "gameFull" {
                    state = object["state"] as? [String: Any]
                } else if type == "gameState" {
                    state = object
                } else {
                    continue
                }

                guard let state,
                      let moves = state["moves"] as? String else {
                    continue
                }

                currentMoves = moves.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )

                let gameStatus = state["status"] as? String ?? "started"
                if gameStatus != "started" {
                    status = "Game status: \(gameStatus)"
                    writeLog("Game status: \(gameStatus).")
                    return
                }

                searchIfNeeded()
            }
        } catch {
            if !Task.isCancelled {
                writeLog("Game stream interrupted.")
            }
        }
    }

    private func searchIfNeeded() {
        guard engineReady,
              !searching,
              !movePending,
              gameID != nil,
              let botColor else { return }

        let moves = currentMoves
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let sideToMove = moves.count.isMultiple(of: 2) ? "white" : "black"
        guard sideToMove == botColor else { return }
        guard searchedMoves != currentMoves else { return }

        searchedMoves = currentMoves
        searching = true

        if moves.isEmpty {
            engine?.sendCommand("position startpos")
        } else {
            engine?.sendCommand(
                "position startpos moves " + moves.joined(separator: " ")
            )
        }

        engine?.sendCommand("go movetime 150")
    }

    private func submitMove(
        _ move: String,
        game id: String,
        position: String
    ) async {
        do {
            let request = makeRequest(
                "/api/bot/game/\(id)/move/\(move)",
                method: "POST"
            )
            let (data, response) = try await URLSession.shared.data(
                for: request
            )

            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? ""
                writeLog("Move rejected (HTTP error): \(message)")
                movePending = false
                searchedMoves = nil
                return
            }

            writeLog("Played \(move).")
            movePending = false

            // If the stream already advanced, check whether it is our turn.
            // Otherwise, wait for the next game-state update.
            if currentMoves == position {
                searchedMoves = position
            }
            searchIfNeeded()
        } catch {
            writeLog("Move request failed.")
            movePending = false
            searchedMoves = nil
        }
    }
}

private enum LichessTokenStore {
    private static let service = "SwiftChessDemo.LichessBot"

    static func save(_ token: String) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "bot-token"
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemUpdate(query as CFDictionary,
                                   attributes as CFDictionary)

        if status == errSecItemNotFound {
            var newItem = query
            attributes.forEach { newItem[$0.key] = $0.value }
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw TokenStoreError.keychain(addStatus)
            }
        } else if status != errSecSuccess {
            throw TokenStoreError.keychain(status)
        }
    }

    static func load() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "bot-token",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            throw TokenStoreError.keychain(status)
        }

        return token
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "bot-token"
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStoreError.keychain(status)
        }
    }
}

private enum TokenStoreError: Error {
    case keychain(OSStatus)
}
