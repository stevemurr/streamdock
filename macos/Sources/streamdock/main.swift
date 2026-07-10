import Foundation
import StreamDockCore

// The `streamdock` CLI: lets one key's shell/AppleScript action press other
// keys and switch pages through the app's control socket. Kept deliberately
// thin — request building and response parsing live in StreamDockCore
// (ControlProtocol.swift) where they are unit-tested.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

if let first = arguments.first, ["help", "-h", "--help"].contains(first) {
    print(ControlCLI.usageText)
    exit(0)
}

let depth = environment["STREAMDOCK_PRESS_DEPTH"].flatMap(Int.init) ?? 0

let request: ControlRequest
do {
    request = try ControlCLI.makeRequest(arguments: arguments, depth: depth)
} catch {
    fail(error.localizedDescription)
}

guard let socketPath = environment["STREAMDOCK_SOCKET"], !socketPath.isEmpty else {
    fail("""
    STREAMDOCK_SOCKET is not set.
    This tool is meant to run from a StreamDock key action, where the app \
    provides the control socket automatically. To try it by hand while the \
    app is running:
      export STREAMDOCK_SOCKET="$HOME/Library/Application Support/StreamDock/control.sock"
    """)
}

do {
    let response = try ControlClient.send(request, socketPath: socketPath)
    guard response.ok else { fail(response.error ?? "request failed") }
    if request.command == ControlCommand.list, let keys = response.keys {
        for key in keys {
            print("\(key.page)\t\(key.position)\t\(key.label)")
        }
    } else if let detail = response.detail {
        print(detail)
    }
    exit(0)
} catch {
    fail(error.localizedDescription)
}
