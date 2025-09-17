import Cocoa
import FlutterMacOS
import Carbon

// Swift Services provider to accept text/link drops on the Dock icon.
// Exposed to ObjC runtime so host can instantiate via NSClassFromString in AppDelegate.
@objc(DesktopDropServicesProvider)
public class DesktopDropServicesProvider: NSObject {
  private static var pending: [[String: Any]] = []

  private func enqueueAndPost(_ dict: [String: Any]) {
    DesktopDropServicesProvider.pending.append(dict)
    NotificationCenter.default.post(
      name: Notification.Name("desktop_drop.servicePayload"),
      object: nil,
      userInfo: ["items": [dict]]
    )
  }

  // Queried by the plugin after registration to drain any pre-launch payloads.
  @objc public func desktopDropFetchPendingServicePayloads() -> [Any] {
    let copy = DesktopDropServicesProvider.pending
    DesktopDropServicesProvider.pending.removeAll()
    return copy
  }

  // NSServices entry point (Info.plist: NSMessage = desktopDropAcceptDroppedText).
  @objc public func desktopDropAcceptDroppedText(
    _ pboard: NSPasteboard,
    userData: String,
    error: AutoreleasingUnsafeMutablePointer<NSString?>?
  ) {
    if let s = pboard.string(forType: .string), let data = s.data(using: .utf8) {
      enqueueAndPost([
        "data": FlutterStandardTypedData(bytes: data),
        "mimeType": "text/plain; charset=utf-8",
        "name": "Dock Dropped Text.txt",
        "fromPromise": false,
      ])
      return
    }
    if let html = pboard.string(forType: .html), let data = html.data(using: .utf8) {
      enqueueAndPost([
        "data": FlutterStandardTypedData(bytes: data),
        "mimeType": "text/html; charset=utf-8",
        "name": "Dock Dropped Text.html",
        "fromPromise": false,
      ])
      return
    }
    if let rtf = pboard.data(forType: .rtf) {
      enqueueAndPost([
        "data": FlutterStandardTypedData(bytes: rtf),
        "mimeType": "application/rtf",
        "name": "Dock Dropped Text.rtf",
        "fromPromise": false,
      ])
      return
    }
    if let urlString = pboard.string(forType: .URL), let data = urlString.data(using: .utf8) {
      enqueueAndPost([
        "data": FlutterStandardTypedData(bytes: data),
        "mimeType": "text/uri-list",
        "name": "Dock Dropped URL.txt",
        "fromPromise": false,
      ])
      return
    }
  }
}

private func findFlutterViewController(_ viewController: NSViewController?) -> FlutterViewController? {
  guard let vc = viewController else {
    return nil
  }
  if let fvc = vc as? FlutterViewController {
    return fvc
  }
  for child in vc.children {
    let fvc = findFlutterViewController(child)
    if fvc != nil {
      return fvc
    }
  }
  return nil
}

public class DesktopDropPlugin: NSObject, FlutterPlugin, FlutterAppLifecycleDelegate {

  // Keep a reference to the channel so we can invoke from app delegate callbacks.
  private var channel: FlutterMethodChannel!
  private var pendingOpenItems: [[String: Any]] = []
  private var didFinishLaunching = false
  private var dartReady = false
  private var dropTargetInstalled = false

  private func currentFlutterViewController() -> FlutterViewController? {
    // Try to find an existing FlutterViewController among app windows
    for window in NSApp.windows {
      if let fvc = findFlutterViewController(window.contentViewController) {
        return fvc
      }
    }
    // Fallback to key/main windows
    if let fvc = findFlutterViewController(NSApp.keyWindow?.contentViewController) { return fvc }
    if let fvc = findFlutterViewController(NSApp.mainWindow?.contentViewController) { return fvc }
    return nil
  }

  private func tryInstallDropTarget() {
    if dropTargetInstalled { return }
    guard let vc = currentFlutterViewController() else { return }
    let d = DropTarget(frame: vc.view.bounds, channel: channel)
    d.autoresizingMask = [.width, .height]
    var types = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    types.append(.fileURL)
    types.append(NSPasteboard.PasteboardType("NSFilenamesPboardType"))
    // Accept common text and link types for in-window drops.
    types.append(.string)  // public.utf8-plain-text
    types.append(.html)    // public.html
    types.append(.rtf)     // public.rtf
    types.append(.URL)     // public.url (http/https/mailto, etc.)
    d.registerForDraggedTypes(types)
    vc.view.addSubview(d)
    dropTargetInstalled = true
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Register channel and lifecycle delegate.
    // Always set up channel and become an application delegate first.
    let channel = FlutterMethodChannel(name: "desktop_drop", binaryMessenger: registrar.messenger)
    let instance = DesktopDropPlugin()
    instance.channel = channel
    channel.setMethodCallHandler(instance.handle(_:result:))
    registrar.addMethodCallDelegate(instance, channel: channel)
    registrar.addApplicationDelegate(instance)
    // Plugin registered; app lifecycle delegate attached.

    // Try to install the in-window DropTarget if the Flutter view is available.
    instance.tryInstallDropTarget()

    // Also observe app/window activation to install later if needed.
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      instance.tryInstallDropTarget()
    }
    NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
      instance.tryInstallDropTarget()
    }

    // Consider launch finished by the time plugins are registered.
    // In Flutter macOS templates, plugin registration happens after app launch.
    instance.didFinishLaunching = true
    // If the app was launched via a Dock text drop before plugin registration,
    // pull any queued payloads from the services provider now.
    instance.drainPendingServicePayloads()

    // Services (Dock text) are handled by a provider installed by the host app
    // in applicationWillFinishLaunching. The plugin will drain any pre-launch
    // payloads and will observe runtime payload notifications.

    // Observe runtime service payloads broadcast by the host AppDelegate.
    NotificationCenter.default.addObserver(
      forName: Notification.Name("desktop_drop.servicePayload"),
      object: nil,
      queue: .main
    ) { note in
      guard let items = note.userInfo?["items"] as? [[String: Any]] else { return }
      instance.pendingOpenItems.append(contentsOf: items)
      if instance.didFinishLaunching && instance.dartReady {
        instance.channel.invokeMethod("performOperation_macos", arguments: instance.pendingOpenItems)
        instance.pendingOpenItems.removeAll()
      }
    }

    // Belt-and-suspenders: handle Apple Event for content dropped on Dock icon.
    NSAppleEventManager.shared().setEventHandler(
      instance,
      andSelector: #selector(DesktopDropPlugin.handleOpenContentsEvent(_:withReplyEvent:)),
      forEventClass: AEEventClass(kCoreEventClass),
      andEventID: AEEventID(kAEOpenContents)
    )
  }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult){
 
      if call.method == "readyForGlobalDrops" {
            // Dart side has installed its MethodChannel handler and is ready.
            // Ensure any queued Services payloads are drained before flushing.
            drainPendingServicePayloads()
            dartReady = true
            if didFinishLaunching && !pendingOpenItems.isEmpty {
              channel.invokeMethod("performOperation_macos", arguments: pendingOpenItems)
              pendingOpenItems.removeAll()
            }
            result(true)
            return
      }

      if call.method ==  "startAccessingSecurityScopedResource"{
            let map = call.arguments as! NSDictionary 
            var isStale: Bool = false

          let bookmarkByte = map["apple-bookmark"] as! FlutterStandardTypedData
          let bookmark = bookmarkByte.data
            
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            let suc = url?.startAccessingSecurityScopedResource()
            result(suc) 
            return
      }

      if call.method ==  "stopAccessingSecurityScopedResource"{
            let map = call.arguments as! NSDictionary 
            var isStale: Bool = false 
          let bookmarkByte = map["apple-bookmark"] as! FlutterStandardTypedData
          let bookmark = bookmarkByte.data
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            url?.stopAccessingSecurityScopedResource()
            result(true)
            return
      }

      Swift.print("method not found: \(call.method)")
      result(FlutterMethodNotImplemented)
      return
  }

  // MARK: - FlutterAppLifecycleDelegate (Dock/Finder open handlers)

  public func handleDidFinishLaunching(_ notification: Notification) {
    didFinishLaunching = true
    // Drain any queued service payloads collected by an early services provider (e.g., AppDelegate).
    drainPendingServicePayloads()
    if dartReady && !pendingOpenItems.isEmpty {
      channel.invokeMethod("performOperation_macos", arguments: pendingOpenItems)
      pendingOpenItems.removeAll()
    }
  }

  public func handleOpen(_ urls: [URL]) -> Bool {
    handleOpen(urls: urls)
    return true
  }

  // Attempt to fetch any pending service payloads from the current services provider.
  private func drainPendingServicePayloads() {
    let sel = #selector(DesktopDropServicesProvider.desktopDropFetchPendingServicePayloads)

    func fetch(from obj: Any?) {
      guard let o = obj as? NSObject else { return }
      if o.responds(to: sel), let unmanaged = o.perform(sel) {
        let obj = unmanaged.takeUnretainedValue()
        if let arr = obj as? [Any] {
          for case let dict as [String: Any] in arr {
            pendingOpenItems.append(dict)
          }
        }
      }
    }

    // 1) If the app installed a custom provider, use it.
    fetch(from: NSApp.servicesProvider)
    // 2) Otherwise, fall back to NSApp (category added by the plugin).
    fetch(from: NSApp)
  }

  // Handle AppleEvent kAEOpenContents (text dropped on Dock icon).
  @objc func handleOpenContentsEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
    guard let desc = event.paramDescriptor(forKeyword: keyDirectObject) else { return }
    var items: [[String: Any]] = []

    if desc.descriptorType == typeAEList {
      for i in 1...desc.numberOfItems {
        guard let item = desc.atIndex(i) else { continue }
        if let s = item.stringValue, let data = s.data(using: .utf8) {
          items.append([
            "data": FlutterStandardTypedData(bytes: data),
            "mimeType": "text/plain; charset=utf-8",
            "name": "Dock Dropped Text.txt",
            "fromPromise": false,
          ])
        }
      }
    } else if let s = desc.stringValue, let data = s.data(using: .utf8) {
      items.append([
        "data": FlutterStandardTypedData(bytes: data),
        "mimeType": "text/plain; charset=utf-8",
        "name": "Dock Dropped Text.txt",
        "fromPromise": false,
      ])
    }

    if !items.isEmpty {
      pendingOpenItems.append(contentsOf: items)
      if didFinishLaunching && dartReady {
        channel.invokeMethod("performOperation_macos", arguments: pendingOpenItems)
        pendingOpenItems.removeAll()
      }
    }
  }

  private func handleOpen(urls: [URL]) {
    var items: [[String: Any]] = []

    for url in urls {
      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      let isDirectory: Bool = values?.isDirectory ?? false

      // Only create a security-scoped bookmark for items outside our container/temp.
      let bundleID = Bundle.main.bundleIdentifier ?? ""
      let containerRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true)
        .path
      let tmpPath = FileManager.default.temporaryDirectory.path
      let insideContainer = url.path.hasPrefix(containerRoot) || url.path.hasPrefix(tmpPath)

      let bmData: Any
      if insideContainer {
        bmData = NSNull()
      } else {
        let bm = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        bmData = bm ?? NSNull()
      }

      items.append([
        "path": url.path,
        "apple-bookmark": bmData,
        "isDirectory": isDirectory,
        "fromPromise": false,
      ])
    }

    // Always queue; flush only when both app finished launching and Dart is ready.
    pendingOpenItems.append(contentsOf: items)
    if didFinishLaunching && dartReady {
      channel.invokeMethod("performOperation_macos", arguments: pendingOpenItems)
      pendingOpenItems.removeAll()
    } else {
      // Deferred until both launch finished and Dart is ready.
    }
  }
   
}

class DropTarget: NSView {
  private let channel: FlutterMethodChannel
  private let itemsLock = NSLock()

  init(frame frameRect: NSRect, channel: FlutterMethodChannel) {
    self.channel = channel
    super.init(frame: frameRect)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("entered", arguments: convertPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    channel.invokeMethod("updated", arguments: convertPoint(sender.draggingLocation))
    return .copy
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    channel.invokeMethod("exited", arguments: nil)
  }

  /// Create a per-drop destination for promised files (avoids name collisions).
  private func uniqueDropDestination() -> URL {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("Drops", isDirectory: true)
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd_HHmmss_SSS'Z'"
    let stamp = formatter.string(from: Date())
    let dest = base.appendingPathComponent(stamp, isDirectory: true)
    try? FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: nil)
    return dest
  }

  /// Queue used for reading and writing file promises.
  private lazy var workQueue: OperationQueue = {
    let providerQueue = OperationQueue()
    providerQueue.qualityOfService = .userInitiated
    return providerQueue
  }()

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let pb = sender.draggingPasteboard
    let dest = uniqueDropDestination()
    var items: [[String: Any]] = []
    var seen = Set<String>()
    let group = DispatchGroup()

    func push(url: URL, fromPromise: Bool) {
      let path = url.path
      itemsLock.lock(); defer { itemsLock.unlock() }

      // de-dupe safely under lock
      if !seen.insert(path).inserted { return }

      let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
      let isDirectory: Bool = values?.isDirectory ?? false

      // Only create a security-scoped bookmark for items outside our container.
      let bundleID = Bundle.main.bundleIdentifier ?? ""
      let containerRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/\(bundleID)", isDirectory: true)
        .path
      let tmpPath = FileManager.default.temporaryDirectory.path
      let isInsideContainer = path.hasPrefix(containerRoot) || path.hasPrefix(tmpPath)

      let bmData: Any
      if isInsideContainer {
        bmData = NSNull()
      } else {
        let bm = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        bmData = bm ?? NSNull()
      }
      items.append([
        "path": path,
        "apple-bookmark": bmData,
        "isDirectory": isDirectory,
        "fromPromise": fromPromise,
      ])
    }

    // Prefer real file URLs if they exist; only fall back to promises
    let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    let legacyList = (pb.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String]) ?? []

    if !urls.isEmpty || !legacyList.isEmpty {
      // 1) Modern file URLs
      urls.forEach { push(url: $0, fromPromise: false) }
      // 2) Legacy filename array used by some apps
      legacyList.forEach { push(url: URL(fileURLWithPath: $0), fromPromise: false) }
    } else {
      // 3) Handle file promises (e.g., VS Code, browsers, Mail)
      if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
         !receivers.isEmpty {
        for r in receivers {
          group.enter()
          r.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: self.workQueue) { url, error in
            defer { group.leave() }
            if let error = error {
              debugPrint("NSFilePromiseReceiver error: \(error)")
              return
            }
            push(url: url, fromPromise: true)
          }
        }
      }
    }

    // 4) Add non-file URLs (e.g., http/https links dragged from browsers)
    let anyUrls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: false]) as? [URL]) ?? []
    for u in anyUrls where !u.isFileURL {
      if let data = u.absoluteString.data(using: .utf8) {
        items.append([
          "data": FlutterStandardTypedData(bytes: data),
          "mimeType": "text/uri-list",
          "name": "Dropped URL.txt",
          "fromPromise": false,
        ])
      }
    }

    // 5) Add plain text / HTML / RTF, preferring plain text if available.
    if let s = pb.string(forType: .string), let data = s.data(using: .utf8) {
      items.append([
        "data": FlutterStandardTypedData(bytes: data),
        "mimeType": "text/plain; charset=utf-8",
        "name": "Dropped Text.txt",
        "fromPromise": false,
      ])
    } else if let html = pb.string(forType: .html), let data = html.data(using: .utf8) {
      items.append([
        "data": FlutterStandardTypedData(bytes: data),
        "mimeType": "text/html; charset=utf-8",
        "name": "Dropped Text.html",
        "fromPromise": false,
      ])
    } else if let rtf = pb.data(forType: .rtf) {
      items.append([
        "data": FlutterStandardTypedData(bytes: rtf),
        "mimeType": "application/rtf",
        "name": "Dropped Text.rtf",
        "fromPromise": false,
      ])
    }

    group.notify(queue: .main) {
      self.channel.invokeMethod("performOperation_macos", arguments: items)
    }
    return true
  }

  // Dock text Services are handled by DesktopDropServicesProvider.

  func convertPoint(_ location: NSPoint) -> [CGFloat] {
    return [location.x, bounds.height - location.y]
  }
}
