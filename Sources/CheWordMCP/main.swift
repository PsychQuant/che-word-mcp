import Foundation
import MCP

// Entry point
let server = await WordMCPServer()
try await server.run()
