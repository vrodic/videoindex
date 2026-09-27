import Cocoa

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write("Usage: VideoIndex <root_dir> <index_file>\n".data(using: .utf8)!)
    exit(1)
}

let rootDir = arguments[1]
let indexFile = arguments[2]

let app = NSApplication.shared
let delegate = AppDelegate(rootDir: rootDir, indexFile: indexFile)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
