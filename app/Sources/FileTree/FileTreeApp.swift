import AppKit
import SwiftUI

@main
struct FileTreeApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 640)
    }
}

struct ContentView: View {
    @AppStorage("folder") private var folder = FileManager.default.homeDirectoryForCurrentUser.path
    @AppStorage("pixelSize") private var pixel = 3.0
    @AppStorage("trunkSize") private var thickness = 14.0
    @AppStorage("moss") private var moss = 1.0
    @AppStorage("fontSize") private var fontSize = 16.0
    @AppStorage("speed") private var speed = 1.0
    @AppStorage("showHidden") private var showHidden = false
    @AppStorage("lightBackground") private var light = true

    @State private var model: TreeModel?
    @State private var awake = true
    @State private var showSettings = false
    @State private var dragLast = CGSize.zero
    @State private var scrollMonitor: Any?
    @FocusState private var focused: Bool

    private var style: Style {
        Style(pixel: pixel, thickness: thickness, moss: moss, fontSize: fontSize, speed: speed, light: light)
    }

    var body: some View {
        TimelineView(.animation(paused: !awake)) { timeline in
            Canvas { gc, size in
                guard let model else { return }
                if model.frame(&gc, size: size, now: timeline.date, style: style) {
                    DispatchQueue.main.async { awake = false }
                }
            }
        }
        .background(style.background)
        // no title bar, so the top strip is where the window gets dragged from
        .overlay(alignment: .top) {
            Color.clear.frame(height: 28).contentShape(Rectangle()).gesture(WindowDragGesture())
        }
        .overlay(alignment: .topTrailing) { buttons }
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            // trackpad and wheel scrolling pan the tree
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                let speed: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                model?.pan(event.scrollingDeltaX * speed, event.scrollingDeltaY * speed)
                awake = true
                return event
            }
        }
        .onDisappear {
            if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        }
        .onKeyPress { press in
            guard let model else { return .ignored }
            let keys: [KeyEquivalent: Character] = [.upArrow: "k", .downArrow: "j", .leftArrow: "h", .rightArrow: "l", .return: "\r", .space: " "]
            guard let k = keys[press.key] ?? press.characters.first, "hjkl \r".contains(k) else { return .ignored }
            if let url = model.key(k) { NSWorkspace.shared.open(url) }
            awake = true
            return .handled
        }
        .onTapGesture(coordinateSpace: .local) { point in
            if let url = model?.click(point) { NSWorkspace.shared.open(url) }
            focused = true
            awake = true
        }
        .gesture(DragGesture(minimumDistance: 4)
            .onChanged { drag in
                model?.pan(drag.translation.width - dragLast.width, drag.translation.height - dragLast.height)
                dragLast = drag.translation
                awake = true
            }
            .onEnded { _ in dragLast = .zero })
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard let model else { return }
            var point: CGPoint?
            if case .active(let p) = phase { point = p }
            if model.hover(point) { awake = true }
            (model.hovered == nil ? NSCursor.arrow : NSCursor.pointingHand).set()
        }
        .task(id: "\(folder)|\(showHidden)") {
            model = TreeModel(url: URL(fileURLWithPath: folder), showHidden: showHidden)
            awake = true
        }
        .onChange(of: style) { awake = true }
        .navigationTitle(URL(fileURLWithPath: folder).lastPathComponent)
    }

    private var buttons: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: folder)
                    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
                } label: {
                    Image(systemName: "folder").frame(width: 28, height: 22).contentShape(Rectangle())
                }
                .help("Open Folder")
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 28, height: 22).contentShape(Rectangle())
                }
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    Form {
                        Slider(value: $pixel, in: 1.5...6, step: 0.5) { Text("Pixel size  \(pixel, specifier: "%.1f")") }
                        Slider(value: $thickness, in: 4...24, step: 1) { Text("Branch size  \(Int(thickness))") }
                        Slider(value: $moss, in: 0...2) { Text("Moss  \(Int(moss * 100))%") }
                        Slider(value: $fontSize, in: 9...22, step: 1) { Text("Font size  \(Int(fontSize))") }
                        Slider(value: $speed, in: 0.25...4) { Text("Grow speed  \(speed, specifier: "%.1f")×") }
                        Toggle("Show hidden files", isOn: $showHidden)
                        Toggle("Light background", isOn: $light)
                    }
                    .padding()
                    .frame(width: 320)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        // same centre line as the traffic lights, and inset like them so it clears the window corner
        .padding(.top, 5.5)
        .padding(.trailing, 14)
    }
}
