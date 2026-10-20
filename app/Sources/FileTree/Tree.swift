import AppKit
import SwiftUI
import UniformTypeIdentifiers

// same tree as the c version: directories grow as branches, files hang off twigs.
// layout happens in world units (one unit is `unit` points), then the bark, moss and twigs
// get rasterised into a grid of style.pixel sized pixels so the whole thing reads as pixel art.

struct Style: Equatable {
    var pixel: CGFloat
    var thickness: CGFloat
    var moss: CGFloat
    var fontSize: CGFloat
    var speed: CGFloat
    var light: Bool

    var background: Color { rgb(light ? 0xfdfdfc : 0x0e0e0d) }
}

private let unit: CGFloat = 6
// a branch grows in two passes, timed off the video: a thin tip shoots out to the end in 0.35s,
// then from 0.15s a ripening front follows it from the base over 1.1s, thickening the bark and
// filling in the moss. fixed durations, so a long branch takes no longer than a short one
private let tipTime: CGFloat = 0.35, ripenDelay: CGFloat = 0.15, ripenTime: CGFloat = 1.1
// light to dark, picked by where a pixel sits across the branch
private let bark: [UInt32] = [0xdcd5c8, 0xb5ab9c, 0x8e8477, 0x655c52, 0x3d3530, 0x1d1916]
// deep to bright, picked by how close a pixel is to the middle of its clump
private let moss: [UInt32] = [0x3f8a22, 0x5daa26, 0x7ccc2a, 0x9ee22c, 0xc4f03a, 0xe8f74f]
private let twig: [UInt32] = [0xa59c90, 0x7d746a, 0x5a5249]
private let berry: [UInt32] = [0xc8463a, 0xe0899b]
// 4x4 ordered dither, so shading breaks up into the checkered look of the reference
private let bayer: [CGFloat] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 }

func rgb(_ c: UInt32) -> Color {
    Color(red: Double(c >> 16 & 255) / 255, green: Double(c >> 8 & 255) / 255, blue: Double(c & 255) / 255)
}

private func hash(_ a: Int, _ b: Int, _ c: UInt32) -> UInt32 {
    var x = UInt32(truncatingIfNeeded: a) &* 374761393 &+ UInt32(truncatingIfNeeded: b) &* 668265263 &+ c &* 2246822519
    x = (x ^ (x >> 13)) &* 1274126177
    return x ^ (x >> 16)
}

final class Node {
    let name: String
    let url: URL
    let isDir: Bool
    let seed: UInt32
    let symbol: String // sf symbol for files, folders are drawn by hand
    weak var parent: Node?
    var kids: [Node] = []
    var loaded = false, open = false
    var error: String?
    var grow: CGFloat = 0 // 0..1, how much of the branch the tip has reached
    var age: CGFloat = 0 // seconds the branch has been growing, runs backwards when it closes
    var span: CGFloat = 0 // how far right of its icon the open subtree reaches, from the last frame
    var box: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0) // min x, max x, min y, max y of the shown subtree
    // layout, recomputed every frame. (ix, iy) is the icon, floating beside its parent branch.
    // (ox, oy) is where a file's twig leaves the parent, and where a folder's branch starts: inside its icon
    var ox: CGFloat = 0, oy: CGFloat = 0, ang: CGFloat = 0, len: CGFloat = 0, width: CGFloat = 1
    var ix: CGFloat = 0, iy: CGFloat = 0
    var lean: CGFloat = 0 // the parent's direction where this branch starts
    var at: CGFloat = 0, slot: CGFloat = 0, side: CGFloat = 1
    var lx: CGFloat = 0, ly: CGFloat = 0
    var path: [(CGFloat, CGFloat)] = [] // the branch's centre line, one point every `step` along it
    var traced: [CGFloat] = [] // what the path was traced from, so it's only redone when that changes

    init(url: URL, parent: Node?, isDir: Bool) {
        self.url = url
        self.parent = parent
        self.isDir = isDir
        name = url.lastPathComponent
        seed = url.path.utf8.reduce(2166136261) { ($0 ^ UInt32($1)) &* 16777619 }
        let type = UTType(filenameExtension: url.pathExtension)
        // like the video: a lined page for anything you read as text, a blank page for everything else
        switch true {
        case isDir: symbol = "folder"
        case type?.conforms(to: .text) == true, type?.conforms(to: .pdf) == true: symbol = "doc.text"
        default: symbol = "doc"
        }
    }

    func load(showHidden: Bool) {
        loaded = true
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
                options: showHidden ? [] : [.skipsHiddenFiles])
            // oldest first, the way the video lays its folder out, so new things grow at the tip
            let dated = try urls.map { u in
                let v = try u.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                guard let made = v.creationDate else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: u.path]) }
                return (Node(url: u, parent: self, isDir: v.isDirectory == true), made)
            }
            kids = dated.sorted { a, b in a.1 != b.1 ? a.1 < b.1 : a.0.name.localizedStandardCompare(b.0.name) == .orderedAscending }.map { $0.0 }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

final class TreeModel {
    let root: Node
    var selected: Node
    private(set) var hovered: Node?
    private let showHidden: Bool
    private var style = Style(pixel: 2.5, thickness: 10, moss: 1, fontSize: 13, speed: 1, light: true)
    private var camX: CGFloat = 0, camY: CGFloat = 0, panX: CGFloat = 0, panY: CGFloat = 0
    private var halfW: CGFloat = 0, halfH: CGFloat = 0
    private var last: Date?
    private var lastClick: (Node, Date)?
    private var moving = false
    private var charPx: CGFloat = 1, labelPx: CGFloat = 2, iconPx: CGFloat = 2
    private var grid: [UInt32] = []
    private var gw = 0, gh = 0
    private var shown: [Node] = []
    private var hits: [(Node, CGRect)] = []

    init(url: URL, showHidden: Bool) {
        root = Node(url: url, parent: nil, isDir: true)
        self.showHidden = showHidden
        root.load(showHidden: showHidden)
        root.open = true
        root.ox = -20
        root.lx = -18
        selected = root.kids.first ?? root
    }

    // advances the animation and draws one frame. returns true once nothing is moving
    func frame(_ gc: inout GraphicsContext, size: CGSize, now: Date, style: Style) -> Bool {
        self.style = style
        let dt = CGFloat(last.map { min(0.05, now.timeIntervalSince($0)) } ?? 1.0 / 60)
        last = now
        charPx = style.fontSize * 0.55 / unit
        labelPx = style.fontSize * 1.25 / unit
        iconPx = style.fontSize * 1.6 / unit
        root.width = style.thickness / unit
        halfW = size.width / 2
        halfH = size.height / 2
        gw = Int(size.width / style.pixel) + 1
        gh = Int(size.height / style.pixel) + 1

        moving = false
        _ = measure(root, dt)
        trace(root, start: 0)
        place(root)
        // follow the selection, but keep the trunk pinned to the left edge when it fits
        var fx = selected.lx + CGFloat(selected.name.count) * charPx / 2, fy = selected.ly
        if selected.isDir && selected.grow > 0 && selected !== root {
            // pan along with a growing branch so it stays in view, like the video does
            let mid = point(selected, selected.len * selected.grow * 0.5)
            fx = (fx + mid.0) / 2
            fy = (fy + mid.1) / 2
        }
        let tx = max(fx, halfW / unit - 22) + panX
        let ty = fy + panY
        if abs(tx - camX) > 0.05 || abs(ty - camY) > 0.05 { moving = true }
        camX += (tx - camX) * min(1, dt * 6)
        camY += (ty - camY) * min(1, dt * 6)

        grid = Array(repeating: 0, count: gw * gh)
        shown = []
        draw(root)

        let ink = rgb(style.light ? 0x1c1c1c : 0xf0ede6)
        let faded = rgb(style.light ? 0xbdb8b0 : 0x5e5a55)
        let text = rgb(style.light ? 0x8c8780 : 0x98938b)
        // open folders are drawn in layers: back panel, then the branch growing out of it, then the front flap
        for n in shown where n.isDir && n.grow > 0 { folderBack(&gc, screen(n.ix, n.iy), ink, style.fontSize, tab: false) }
        // the pixels go out as one bitmap, scaled up without smoothing
        let data = grid.withUnsafeBytes { Data($0) } as CFData
        let bitmap = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                             provider: CGDataProvider(data: data)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        gc.draw(Image(decorative: bitmap, scale: 1).interpolation(.none),
                in: CGRect(x: 0, y: 0, width: CGFloat(gw) * style.pixel, height: CGFloat(gh) * style.pixel))

        hits = []
        for n in shown {
            let isSel = n === selected, isHover = n === hovered
            let appear = n.parent.map { min(1, max(0, ($0.len * $0.grow - n.at) / 5)) } ?? 1
            let fs = style.fontSize * (0.6 + 0.4 * appear)
            var gc = gc
            gc.opacity = appear
            let label = gc.resolve(Text(n.isDir ? n.name + "/" : n.name)
                .font(.system(size: style.fontSize, weight: .medium)).foregroundColor(isSel || isHover ? ink : text))
            let tsz = label.measure(in: CGSize(width: 4000, height: 400))
            let ip = screen(n.ix, n.iy), lp = screen(n.lx, n.ly)
            if lp.x > size.width + 40 || lp.x < -800 || lp.y < -40 || lp.y > size.height + 40 { continue }
            let textRect = CGRect(x: lp.x - 5, y: lp.y - tsz.height / 2 - 2, width: tsz.width + 10, height: tsz.height + 4)
            let iconRect = CGRect(x: ip.x - style.fontSize * 0.9, y: ip.y - style.fontSize * 0.8, width: style.fontSize * 1.8, height: style.fontSize * 1.6)
            // the text gets a clear patch so branches never run through it. like the video there's no
            // highlight, the selected or hovered item just turns dark
            gc.fill(Path(roundedRect: textRect, cornerRadius: textRect.height / 2), with: .color(style.background))
            if !n.isDir {
                gc.draw(Text(Image(systemName: n.symbol)).font(.system(size: fs * 1.6, weight: .regular))
                    .foregroundColor(isSel || isHover ? ink : faded), at: ip, anchor: .center)
            } else if n.grow > 0 {
                folderFlap(&gc, ip, ink, fs)
            } else {
                folderBack(&gc, ip, isSel || isHover ? ink : faded, fs, tab: true)
            }
            gc.draw(label, at: lp, anchor: .leading)
            if appear > 0.5 { hits.append((n, textRect.union(iconRect))) }
        }

        // the tree fades out under the header so the title and buttons sit on a clean strip
        gc.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 44)),
                with: .linearGradient(Gradient(colors: [style.background, style.background, style.background.opacity(0)]),
                                      startPoint: .zero, endPoint: CGPoint(x: 0, y: 44)))
        // the root folder is the window title, like the finder window in the video
        gc.draw(Text("\(Image(systemName: "folder"))  \(root.name)").font(.system(size: 13, weight: .semibold)).foregroundColor(text),
                at: CGPoint(x: halfW, y: 16.5), anchor: .center)
        let items = selected.parent?.kids.count ?? root.kids.count
        let status = selected.error.map { "\(selected.name): \($0)" } ?? "\(items) items"
        gc.draw(Text(status).font(.system(size: 11)).foregroundColor(text), at: CGPoint(x: halfW, y: size.height - 12), anchor: .center)
        return !moving
    }

    // returns a file url when the user asked to open it
    func key(_ k: Character) -> URL? {
        let p = selected.parent
        let idx = p?.kids.firstIndex { $0 === selected } ?? 0
        panX = 0
        panY = 0
        switch k {
        case "j", "k":
            if let p { selected = p.kids[(idx + (k == "j" ? 1 : p.kids.count - 1)) % p.kids.count] }
        case "l":
            if selected.isDir && !selected.open { toggle(selected) } else if selected.isDir, let first = selected.kids.first { selected = first }
        case "h":
            if selected.isDir && selected.open && selected !== root { toggle(selected) } else if let p, p !== root { selected = p }
        case " ", "\r":
            if !selected.isDir { return k == "\r" ? selected.url : nil }
            if selected !== root { toggle(selected) }
        default:
            break
        }
        return nil
    }

    // a click toggles folders, a double click opens files
    func click(_ point: CGPoint) -> URL? {
        guard let hit = hits.last(where: { $0.1.contains(point) })?.0 else { return nil }
        let now = Date()
        let double = lastClick.map { $0.0 === hit && now.timeIntervalSince($0.1) < NSEvent.doubleClickInterval } == true
        lastClick = (hit, now)
        panX = 0
        panY = 0
        defer { selected = hit }
        if hit.isDir {
            // the second click of a double click would just close it again
            if !double { toggle(hit) }
            return nil
        }
        return double ? hit.url : nil
    }

    // returns true when the hovered item changed and the frame needs redrawing
    func hover(_ point: CGPoint?) -> Bool {
        let hit = point.flatMap { p in hits.last { $0.1.contains(p) }?.0 }
        defer { hovered = hit }
        return hit !== hovered
    }

    // move the view by a mouse drag or scroll, in points
    func pan(_ dx: CGFloat, _ dy: CGFloat) {
        panX -= dx / unit
        panY -= dy / unit
        camX -= dx / unit
        camY -= dy / unit
    }

    private func toggle(_ n: Node) {
        if n.open {
            close(n)
            var a: Node? = selected
            while let x = a {
                if x === n { selected = n }
                a = x.parent
            }
        } else {
            if !n.loaded { n.load(showHidden: showHidden) }
            n.open = true
        }
    }

    private func close(_ n: Node) {
        n.open = false
        for k in n.kids where k.open { close(k) }
    }

    // walks the branch out from its origin. a folder's branch leaves its mouth heading straight up,
    // swings round onto its own heading, then eases back towards its parent's direction near the
    // tip, never past it, so it levels off without crossing back. the trunk instead
    // keeps a gentle s-wave with a bounded height, like the video
    private func trace(_ n: Node, start: CGFloat) {
        let key = [n.ox, n.oy, n.ang, n.lean, n.len, start]
        if key == n.traced { return }
        n.traced = key
        let step: CGFloat = 0.25, phase = CGFloat(n.seed % 100)
        var x = n.ox, y = n.oy, s: CGFloat = 0
        n.path.removeAll(keepingCapacity: true)
        while s <= n.len + 2 {
            n.path.append((x, y))
            let target = n === root
                ? 0.22 * sin(.pi * s / 70 + 2.2)
                : n.lean + (n.ang - n.lean) * (1 - 0.7 * level(s / n.len)) + 0.08 * sin(.pi * s / 50 + phase)
            let heading = target + (start - target) * exp(-s / 4)
            x += cos(heading) * step
            y += sin(heading) * step
            s += step
        }
    }

    // 0 over the first half of a branch, easing up to 1 at its tip, so branches level off near the end
    private func level(_ t: CGFloat) -> CGFloat {
        let u = min(1, max(0, (t - 0.5) / 0.5))
        return u * u * (3 - 2 * u)
    }

    // point at distance s along a traced branch
    private func point(_ n: Node, _ s: CGFloat) -> (CGFloat, CGFloat) {
        let f = max(0, s) / 0.25, i = min(Int(f), n.path.count - 2), t = min(1, f - CGFloat(i))
        let a = n.path[i], b = n.path[i + 1]
        return (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
    }

    // bottom-up: animate growth and work out how long every open branch needs to be
    private func measure(_ n: Node, _ dt: CGFloat) -> CGFloat {
        guard n.isDir else { return 0 }
        // opening runs the clock forward until the branch is fully ripe, closing winds it back fast
        let ripe = ripenDelay + ripenTime + 0.3, before = n.age
        // closing goes deepest first like the video: a folder only starts pulling back once
        // every subfolder inside it has fully retracted
        let waiting = !n.open && n.kids.contains { $0.age > 0 }
        n.age = n.open ? min(ripe, n.age + dt * style.speed) : waiting ? n.age : max(0, n.age - dt * style.speed * 7)
        if n.age != before { moving = true }
        // items alternate sides. each gets room for its label, and an open folder also keeps everything
        // it has grown clear of later items, but only those on its own side of the branch
        var s: CGFloat = 10, above: CGFloat = 0, below: CGFloat = 0
        for (i, k) in n.kids.enumerated() {
            _ = measure(k, dt)
            // the trunk starts with an item above it, every other branch with one below, like the video
            k.side = (i % 2 == 0) == (n === root) ? -1 : 1
            k.slot = 12 + CGFloat(k.name.count + 4) * charPx * 0.9
            k.at = max(s, k.side < 0 ? above : below) + k.slot / 2
            s = k.at + k.slot / 2
            if k.side < 0 { above = s + k.span } else { below = s + k.span }
        }
        n.len = max(s, above, below) + 6
        n.grow = min(1, n.age / tipTime)
        return n.len * n.grow
    }

    // top-down: float every child beside its parent's branch, alternating sides. open folders
    // keep their whole subtree on their own side of the parent and own a stretch of it, so
    // branches never run into each other
    private func place(_ n: Node) {
        for (i, k) in n.kids.enumerated() {
            (k.ox, k.oy) = point(n, k.at)
            let (jx, jy) = (k.ox, k.oy)
            // every branch turns the same fixed amount away from its parent's direction at the junction,
            // so the tree fans out in long diagonals like the video and branches keep moving apart
            let ahead = point(n, k.at + 0.5)
            k.lean = atan2(ahead.1 - k.oy, ahead.0 - k.ox)
            // hanging branches dive a little steeper than climbing ones, like meadow/ in the video
            k.ang = max(-1.3, min(1.3, k.lean + k.side * (k.side > 0 ? 1.0 : 0.75)))
            // a branch facing back towards the grandparent turns at most until it runs parallel to it
            // (old-oak under woodland runs level in the video), so it can never close in on it
            if n !== root && k.side != n.side { k.ang = k.side > 0 ? min(k.ang, n.lean) : max(k.ang, n.lean) }
            k.width = max(0.9, n.width * (1 - k.at / n.len * 0.3) * 0.85)
            // far enough out that the icon clears the parent's bark and moss, with a visible gap
            let here = n.width * (1 - 0.35 * k.at / n.len)
            let hook: CGFloat = k.isDir && k.side > 0 ? 6 : 0
            let stalk = here / 2 + iconPx * 0.5 + hook + ((i / 2) % 2 == 1 ? 6 : 2.5)
            // out to the side across the parent's direction there, a little ahead of the junction,
            // so items on a steep branch still sit on either side of it rather than in its path
            k.ix = jx - sin(k.lean) * k.side * stalk + cos(k.lean) * stalk * 0.3
            k.iy = jy + cos(k.lean) * k.side * stalk + sin(k.lean) * stalk * 0.3
            // a folder's branch doesn't join its parent, it grows up out of the folder itself
            if k.isDir {
                (k.ox, k.oy) = (k.ix, k.iy - iconPx * 0.1)
                trace(k, start: -.pi / 2)
            }
            // text goes right of the icon, or underneath for folders hanging under the branch,
            // so their branch has room to hook over the top
            let under: CGFloat = k.isDir && k.side > 0 ? 1 : 0
            let rightX = k.ix + iconPx / 2 + 1.2, rightY = k.iy - k.side * labelPx * 0.2
            let underX = k.ix - CGFloat(k.name.count + 1) * charPx * 0.5, underY = k.iy + iconPx * 0.5 + labelPx * 0.6
            k.lx = rightX + (underX - rightX) * under
            k.ly = rightY + (underY - rightY) * under
            guard k.isDir else { continue }
            place(k)

            // bounding box of what this folder has grown: its branch with the end fork, its children,
            // and their own subtrees. the folder itself and the mouth of its branch never move
            let vlen = k.len * k.grow
            var box = (k.ix, k.ix, k.iy, k.iy)
            var j = 24
            while j < k.path.count && CGFloat(j) * 0.25 <= vlen {
                let p = k.path[j], pad = k.width + 2
                box = (min(box.0, p.0), max(box.1, p.0 + (CGFloat(j) * 0.25 > k.len - 2 ? 9 : 0)), min(box.2, p.1 - pad), max(box.3, p.1 + pad))
                j += 4
            }
            for c in k.kids where c.at <= vlen {
                box = (min(box.0, c.ix - iconPx / 2), max(box.1, c.lx + CGFloat(c.name.count + 2) * charPx),
                       min(box.2, min(c.iy - iconPx / 2, c.ly - labelPx / 2)), max(box.3, max(c.iy + iconPx / 2, c.ly + labelPx / 2)))
                if c.isDir && c.grow > 0 { box = (min(box.0, c.box.0), max(box.1, c.box.1), min(box.2, c.box.2), max(box.3, c.box.3)) }
            }
            box = (min(box.0, k.ix - iconPx / 2), max(box.1, k.lx + CGFloat(k.name.count + 2) * charPx),
                   min(box.2, k.iy - iconPx / 2), max(box.3, max(k.iy + iconPx / 2, k.ly + labelPx / 2)))
            k.box = box
            k.span = max(0, box.1 - (k.lx + CGFloat(k.name.count + 2) * charPx))

        }
    }

    private func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - camX) * unit + halfW, y: (y - camY) * unit + halfH)
    }

    // world point to raster pixel coordinates
    private func raster(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) {
        ((x - camX) * unit / style.pixel + halfW / style.pixel, (y - camY) * unit / style.pixel + halfH / style.pixel)
    }

    private func put(_ x: Int, _ y: Int, _ c: UInt32) {
        if x >= 0 && x < gw && y >= 0 && y < gh { grid[y * gw + x] = 0xff000000 | c }
    }

    // hand drawn folder outline: a rounded body, plus the tab on top when it's closed.
    // an open folder is this back panel, its branch, then the front flap tilted over both
    private func folderBack(_ gc: inout GraphicsContext, _ c: CGPoint, _ ink: Color, _ fs: CGFloat, tab: Bool) {
        let w = fs * 1.55, h = fs * 1.35
        let l = c.x - w / 2, t = c.y - h / 2, rad = fs * 0.24, y1 = t + h * 0.2
        var p = Path()
        if tab {
            p.move(to: CGPoint(x: l, y: y1 + rad))
            p.addLine(to: CGPoint(x: l, y: t + rad))
            p.addQuadCurve(to: CGPoint(x: l + rad, y: t), control: CGPoint(x: l, y: t))
            p.addLine(to: CGPoint(x: l + w * 0.42, y: t))
            p.addQuadCurve(to: CGPoint(x: l + w * 0.56, y: y1), control: CGPoint(x: l + w * 0.52, y: t))
            p.addRoundedRect(in: CGRect(x: l, y: y1, width: w, height: t + h - y1), cornerSize: CGSize(width: rad, height: rad))
        } else {
            p.addRoundedRect(in: CGRect(x: l, y: t, width: w, height: h), cornerSize: CGSize(width: rad, height: rad))
        }
        gc.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1.1, fs * 0.09), lineCap: .round, lineJoin: .round))
    }

    private func folderFlap(_ gc: inout GraphicsContext, _ c: CGPoint, _ ink: Color, _ fs: CGFloat) {
        let w = fs * 1.55, h = fs * 1.35
        let l = c.x - w / 2, t = c.y - h / 2, r = l + w, b = t + h, yf = t + h * 0.2, rad = fs * 0.12
        var p = Path()
        p.move(to: CGPoint(x: l + w * 0.2, y: yf))
        p.addLine(to: CGPoint(x: r + w * 0.08 - rad, y: yf))
        p.addQuadCurve(to: CGPoint(x: r + w * 0.07, y: yf + rad), control: CGPoint(x: r + w * 0.08, y: yf))
        p.addLine(to: CGPoint(x: r - w * 0.03, y: b - rad))
        p.addQuadCurve(to: CGPoint(x: r - w * 0.03 - rad, y: b), control: CGPoint(x: r - w * 0.035, y: b))
        p.addLine(to: CGPoint(x: l + rad, y: b))
        p.addQuadCurve(to: CGPoint(x: l + rad * 0.2, y: b - rad), control: CGPoint(x: l, y: b))
        p.closeSubpath()
        gc.fill(p, with: .color(style.background))
        gc.stroke(p, with: .color(ink), style: StrokeStyle(lineWidth: max(1.1, fs * 0.09), lineCap: .round, lineJoin: .round))
    }

    private func draw(_ n: Node) {
        let scale = unit / style.pixel, vlen = n.len * n.grow, ripe = max(0, n.age - ripenDelay) / ripenTime * (n.len + 12)
        // only paint what lands on screen, plus a margin for the widest clump
        let m = CGFloat(40), w = CGFloat(gw), h = CGFloat(gh)
        func onScreen(_ x: CGFloat, _ y: CGFloat) -> Bool { x > -m && x < w + m && y > -m && y < h + m }

        // bark: a shaded tube, light along the top and dark along the bottom edge,
        // thinning into a dotted hairline at the growing tip
        var s: CGFloat = 0
        while s < vlen {
            let p = point(n, s), q = point(n, s + 0.25)
            let tl = hypot(q.0 - p.0, q.1 - p.1), tx = (q.0 - p.0) / tl, ty = (q.1 - p.1) / tl
            let (rx, ry) = raster(p.0, p.1)
            if !onScreen(rx, ry) {
                s += 0.4 / scale
                continue
            }
            let young = min(1, max(0, (ripe - s) / 12)), thick = young * young * (3 - 2 * young)
            let r = max(0.5, n.width * scale * 0.5 * (1 - 0.35 * s / n.len) * (0.22 + 0.78 * thick) * min(1, max(0.25, (n.len - s) / 8)))
            let ir = Int(ceil(r))
            for dy in -ir...ir {
                for dx in -ir...ir {
                    let fx = CGFloat(dx), fy = CGFloat(dy)
                    guard fx * fx + fy * fy <= r * r + 0.25 else { continue }
                    let px = Int(rx.rounded()) + dx, py = Int(ry.rounded()) + dy
                    if r < 1 && s > n.len - 8 && (px + py) & 1 != 0 { continue }
                    let h = hash(px, py, n.seed)
                    let across = (fx * -ty + fy * tx) / max(r, 0.5)
                    // young bark is a thin dark line, it lightens as it ripens
                    let v = (across + 1) / 2 + 0.12 + (1 - thick) * 0.35 + (CGFloat(h % 100) / 100 - 0.5) * 0.45 + (bayer[(px & 3) * 4 + (py & 3)] - 0.5) * 0.3
                    put(px, py, bark[Int(min(0.999, max(0, v)) * CGFloat(bark.count))])
                }
            }
            s += 0.4 / scale
        }

        // moss: dithered clumps, mostly riding on top of the branch, heavy at the base and
        // thinning out towards the tip. they bloom in a moment after the bark grows past them
        var i = 0
        while true {
            let h = hash(i, 7, n.seed)
            let sc = 1 + CGFloat(i) * 1.5 + CGFloat(h % 100) / 80
            i += 1
            if sc >= vlen { break }
            if h % 5 < 2 { continue }
            let life = min(1, (ripe - sc) / 8), base = pow(max(0, 1 - 0.75 * sc / n.len), 1.2)
            guard life > 0 else { continue }
            let size = (n.width * scale * 0.5 + 1) * (0.5 + CGFloat((h >> 8) % 100) / 120) * base * style.moss * life * 1.3
            guard size >= 0.7 else { continue }
            let p = point(n, sc), q = point(n, sc + 0.25)
            let tl = hypot(q.0 - p.0, q.1 - p.1), tx = (q.0 - p.0) / tl, ty = (q.1 - p.1) / tl
            let (rx, ry) = raster(p.0, p.1)
            if !onScreen(rx, ry) { continue }
            let r = n.width * scale * 0.5 * (1 - 0.35 * sc / n.len)
            let lift = h % 4 == 0 ? r * 0.8 : -r * 1.1
            let cx = rx - ty * lift + CGFloat(Int((h >> 16) % 5) - 2), cy = ry + tx * lift
            let a = size * 1.5, b = size, ia = Int(ceil(a))
            for dy in -ia...ia {
                for dx in -ia...ia {
                    let fx = CGFloat(dx), fy = CGFloat(dy)
                    let along = fx * tx + fy * ty, across = fx * -ty + fy * tx
                    let d = along * along / (a * a) + across * across / (b * b)
                    guard d < 1 else { continue }
                    let px = Int(cx.rounded()) + dx, py = Int(cy.rounded()) + dy
                    let hh = hash(px, py, n.seed &+ 99)
                    if (1 - d) * 1.05 < bayer[(px & 3) * 4 + (py & 3)] * 0.75 + CGFloat(hh % 100) / 250 { continue }
                    // brighter towards the middle and the sunny top of each clump
                    let tone = (1 - d) * 0.6 + CGFloat(hh % 100) / 100 * 0.45 - across / b * 0.3 - 0.05
                    put(px, py, hh % 53 == 0 ? berry[Int(hh % 2)] : moss[Int(min(0.999, max(0, tone)) * CGFloat(moss.count))])
                }
            }
        }

        // twigs: long dotted sprigs, some forked, some with a tuft at the end
        var j = 0
        while true {
            let h = hash(j, 31, n.seed)
            let st = 2.5 + CGFloat(j) * 3.2 + CGFloat(h % 100) / 50
            j += 1
            if st >= vlen - 1 { break }
            if h % 3 != 0 { continue }
            let p = point(n, st), q = point(n, st + 0.25)
            let a = atan2(q.1 - p.1, q.0 - p.0) + (h & 1 == 0 ? 1 : -1) * (0.45 + CGFloat((h >> 4) % 60) / 100)
            let tl = (2 + CGFloat((h >> 10) % 40) / 10) * (1 - 0.5 * st / n.len) * min(1, (vlen - st) / 5) * scale
            let (rx, ry) = raster(p.0, p.1)
            if !onScreen(rx, ry) { continue }
            let fork = (rx + cos(a) * tl * 0.55, ry + sin(a) * tl * 0.55, a + (h & 2 == 0 ? 0.55 : -0.55), tl * 0.45)
            for (sx, sy, sa, sl) in [(rx, ry, a, tl), fork] where sl > 1 {
                var t: CGFloat = 1
                while t < sl {
                    if Int(t) & 1 == 0 { put(Int((sx + cos(sa) * t).rounded()), Int((sy + sin(sa) * t).rounded()), twig[Int(t) % 3]) }
                    t += 1
                }
                if h % 4 == 0 { put(Int((sx + cos(sa) * sl).rounded()), Int((sy + sin(sa) * sl).rounded()), moss[Int(h % 6)]) }
            }
        }

        // every branch ends by splitting into a few thin dotted twigs
        let over = (n.age - tipTime) * 40
        if over > 0 {
            let p = point(n, n.len - 1), q = point(n, n.len)
            let (rx, ry) = raster(q.0, q.1)
            for f in 0..<3 {
                let h = hash(f, 77, n.seed)
                if f == 2 && h % 2 == 0 { continue }
                let a = atan2(q.1 - p.1, q.0 - p.0) + [-0.55, 0.5, 0.05][f]
                let tl = (5 + CGFloat(h % 6)) * scale * min(1, over / 8)
                var t: CGFloat = 1
                while t < tl {
                    if Int(t) & 1 == 0 { put(Int((rx + cos(a) * t).rounded()), Int((ry + sin(a) * t).rounded()), twig[Int(t) % 3]) }
                    t += 1
                }
            }
        }

        for (i, k) in n.kids.enumerated() where k.at <= vlen {
            shown.append(k)
            if k.isDir {
                // skip a whole subtree when everything it grew last frame is off screen
                let (x0, y0) = raster(k.box.0, k.box.2), (x1, y1) = raster(k.box.1, k.box.3)
                if k.grow > 0 && x1 > -m && x0 < w + m && y1 > -m && y0 < h + m { draw(k) }
                continue
            }
            // a dotted twig reaching out to the file, stopping short of its icon
            let (ax, ay) = raster(k.ox, k.oy), (bx, by) = raster(k.ix, k.iy)
            let tl = hypot(bx - ax, by - ay), stop = tl - iconPx * scale * 0.45
            var t: CGFloat = 0
            while t < stop {
                if Int(t) & 1 == 0 { put(Int((ax + (bx - ax) * t / tl).rounded()), Int((ay + (by - ay) * t / tl).rounded()), twig[i % 3]) }
                t += 1
            }
        }
    }
}
