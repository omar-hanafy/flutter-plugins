# desktop_drop

[![Pub](https://img.shields.io/pub/v/desktop_drop.svg)](https://pub.dev/packages/desktop_drop)

A plugin which allows user dragging files to your flutter desktop applications.

|         |            |
|---------|------------|
| Windows | ✅          |
| Linux   | ✅          |
| macOS   | ✅          |
| Android | ✅(preview) |
| Web     | ✅          |

## Getting Started

1. Add `desktop_drop` to your `pubspec.yaml`.

```yaml
  desktop_drop: $latest_version
```

2. Then you can use `DropTarget` to receive file drop events.

```dart
class ExampleDragTarget extends StatefulWidget {
  const ExampleDragTarget({Key? key}) : super(key: key);

  @override
  _ExampleDragTargetState createState() => _ExampleDragTargetState();
}

class _ExampleDragTargetState extends State<ExampleDragTarget> {
  final List<XFile> _list = [];

  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return DropTarget(
      onDragDone: (detail) {
        setState(() {
          _list.addAll(detail.files);
        });
      },
      onDragEntered: (detail) {
        setState(() {
          _dragging = true;
        });
      },
      onDragExited: (detail) {
        setState(() {
          _dragging = false;
        });
      },
      child: Container(
        height: 200,
        width: 200,
        color: _dragging ? Colors.blue.withOpacity(0.4) : Colors.black26,
        child: _list.isEmpty
            ? const Center(child: Text("Drop here"))
            : Text(_list.join("\n")),
      ),
    );
  }
}

```

## LICENSE

see LICENSE file

## macOS: Global Drops

On macOS there are two ways users “drop” content into your app:

- In-window drag & drop over your UI (`DropTarget`).
- Drop on the app’s Dock icon (or “Open With” from Finder), which is an application-level open.

Below are minimal, copy‑paste setups for both global cases.

### 1) Files/Folders via Dock/Finder (Info.plist only)

Add this to your macOS `Info.plist` (Runner target) so Dock/Finder route files and folders to your app:

```xml
<!-- Advertise broad document types so Dock/Finder route drops to the app. -->
<key>CFBundleDocumentTypes</key>
<array>
<dict>
    <key>CFBundleTypeRole</key>
    <string>Viewer</string>
    <key>LSItemContentTypes</key>
    <array>
        <string>public.data</string>
        <string>public.folder</string>
    </array>
</dict>
</array>
```

Then initialize the channel early and handle global drops either with a listener or by opting in a widget:

```dart
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  DesktopDrop.instance.init();

  // Optional: global listener for Dock/Finder drops
  DesktopDrop.instance.addRawDropEventListener((event) async {
    if (event is DropDoneEvent && event.location == Offset.zero) {
      // Process files/directories in event.files
    }
  });

 runApp(const MyApp());
}
```

Tip: You can also set `catchAppWideDrops: true` on a single `DropTarget` to receive Dock/Finder drops inside that widget.

### 2) Text/Links via Dock (Info.plist + one AppDelegate line)

macOS delivers selected text and links to apps via Services. To accept text dropped on your Dock icon:

1- Add an `NSServices` entry to your macOS `Info.plist` (include legacy and modern text types):

```xml

<key>NSServices</key>
<array>
<dict>
    <key>NSMenuItem</key>
    <dict>
        <key>default</key>
        <string>Drop Text into Desktop Drop</string>
    </dict>
    <key>NSMessage</key>
    <string>desktopDropAcceptDroppedText</string>
    <key>NSSendTypes</key>
    <array>
        <string>NSStringPboardType</string>
        <string>public.text</string>
        <string>public.plain-text</string>
        <string>public.utf8-plain-text</string>
        <string>public.utf16-plain-text</string>
        <string>public.utf16-external-plain-text</string>
        <string>public.html</string>
        <string>public.rtf</string>
        <string>public.url</string>
    </array>
</dict>
</array>
```

2- Install the Services provider early so Dock text works when launching the app (one line in `AppDelegate.swift`):

```swift
import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationWillFinishLaunching(_ notification: Notification) {
    if NSApp.servicesProvider == nil,
       let cls = NSClassFromString("DesktopDropServicesProvider") as? NSObject.Type {
      NSApp.servicesProvider = cls.init()
    }
 }
}
```

Type-safe handling of text/link drops

The plugin exposes helpers to work with memory-backed text items delivered from Dock Services:

```dart
import 'package:desktop_drop/desktop_drop.dart';

onDragDone: (details) async {
  final fileItems = <DropItem>[];
  for (final item in details.files) {
    if (item.isMemoryBacked && item.isTextLike) {
      final text = await item.readAsText();
      if (text != null && text.trim().isNotEmpty) {
        // Handle plain text / HTML / RTF / uri-list
      }
      continue;
    }
    fileItems.add(item);
  }

  if (fileItems.isNotEmpty) {
    // Handle real files/directories as before
  }
}
```
