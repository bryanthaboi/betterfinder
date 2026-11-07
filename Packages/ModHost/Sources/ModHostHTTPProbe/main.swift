import Foundation
import ModHost
import ModHostProtocol

let arguments = CommandLine.arguments
let cap = arguments.count > 1 ? Int(arguments[1]) ?? 1024 : 1024
let segment = arguments.count > 2 ? Int(arguments[2]) ?? 64 * 1024 : 64 * 1024
let input = FileHandle.standardInput.readDataToEndOfFile()
let reader = ModHTTPResponseReader(bytes: input, segment: segment)
do {
    let response = try await reader.readResponse(method: "GET", cap: cap)
    print("ok \(response.status) \(response.body.count)")
} catch let e as ModCallError {
    print("error \(e.code) \(e.message)")
} catch {
    print("error other \(error)")
}
