import Cocoa

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("Usage: VideoIndex <root_dir> [index_file]\n  index_file defaults to <root_dir>/videoindex.db\n".data(using: .utf8)!)
    exit(1)
}

let rootDir = arguments[1]
let indexFile = arguments.count >= 3
    ? arguments[2]
    : (rootDir as NSString).appendingPathComponent("videoindex.db")

let app = NSApplication.shared
let delegate = AppDelegate(rootDir: rootDir, indexFile: indexFile)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
