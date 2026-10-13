import Cocoa
import FlutterMacOS
import Darwin

class MainFlutterWindow: NSWindow {
  private var scopeURLs: [URL] = []
  private var storeURL: URL {
    // Explicit isolated/portable storage; normal upgrades use the existing path.
    if let directory = ProcessInfo.processInfo.environment["PROTODESK_DATA_DIR"], !directory.isEmpty {
      precondition(directory.hasPrefix("/"), "PROTODESK_DATA_DIR must be absolute")
      return URL(fileURLWithPath: directory, isDirectory: true)
    }
    // Foundation's home APIs are redirected to the sandbox container. The
    // account database supplies the existing desktop application's real path.
    guard let account = getpwuid(getuid()), let directory = account.pointee.pw_dir else {
      fatalError("Unable to resolve the current user's home directory")
    }
    let home = String(cString: directory)
    return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/ProtoDesk")
  }
  private func restoreBookmarks() {
    let file = storeURL.appendingPathComponent("security-bookmarks.plist")
    guard let data = try? Data(contentsOf: file), let bookmarks = try? PropertyListDecoder().decode([String: Data].self, from: data) else { return }
    for (_, bookmark) in bookmarks {
      var stale = false
      if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale), url.startAccessingSecurityScopedResource() {
        scopeURLs.append(url)
      }
    }
  }
  override func awakeFromNib() {
    let controller = FlutterViewController()
    contentViewController = controller
    setContentSize(NSSize(width: 1360, height: 860))
    minSize = NSSize(width: 1000, height: 650)
    RegisterGeneratedPlugins(registry: controller)
    let channel = FlutterMethodChannel(name: "dev.apitools.protodesk/storage", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      if call.method == "dataPath" {
        self.restoreBookmarks()
        result(self.storeURL.appendingPathComponent("protodesk.sqlite").path)
      } else if call.method == "rememberPath", let path = call.arguments as? String {
        do {
          let url = URL(fileURLWithPath: path)
          let bookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
          try FileManager.default.createDirectory(at: self.storeURL, withIntermediateDirectories: true)
          let file = self.storeURL.appendingPathComponent("security-bookmarks.plist")
          var bookmarks: [String: Data] = [:]
          if let data = try? Data(contentsOf: file) { bookmarks = (try? PropertyListDecoder().decode([String: Data].self, from: data)) ?? [:] }
          bookmarks[path] = bookmark
          try PropertyListEncoder().encode(bookmarks).write(to: file, options: .atomic)
          result(nil)
        } catch { result(FlutterError(code: "BOOKMARK", message: error.localizedDescription, details: nil)) }
      } else { result(FlutterMethodNotImplemented) }
    }
    super.awakeFromNib()
  }
}
