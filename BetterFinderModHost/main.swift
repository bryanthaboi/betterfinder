import Foundation
import ModHostRuntime

let delegate = ModHostXPCServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
