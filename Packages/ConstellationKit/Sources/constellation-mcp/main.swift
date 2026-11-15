import ConstellationMCP
import ConstellationProcess
import Foundation

// The helper bundled in Constellation.app. With no arguments it is the stdio MCP server providers
// launch, relaying `request_secret` and `report_outcome` to the app over the bridge socket named in
// the environment. With `--watchdog <dir>` it waits for the app's pipe to close, then stops the
// children the app left in <dir>.
let arguments = CommandLine.arguments
switch arguments.dropFirst().first {
case "--watchdog" where arguments.count == 3:
    await ChildRegistry.runWatchdog(directory: URL(filePath: arguments[2], directoryHint: .isDirectory))

default:
    signal(SIGPIPE, SIG_IGN)
    let environment = ProcessInfo.processInfo.environment
    let client = BridgeClient(
        socketPath: environment[MCPBridge.socketEnvironmentKey] ?? MCPBridge.defaultSocketURL.path(percentEncoded: false),
        sessionID: environment[MCPBridge.sessionIDEnvironmentKey].flatMap(UUID.init(uuidString:))
    )
    let server = MCPServer(backend: client) { data in
        try? FileHandle.standardOutput.write(contentsOf: data)
    }
    await server.run(lines: LineReader.lines(from: STDIN_FILENO))
}
