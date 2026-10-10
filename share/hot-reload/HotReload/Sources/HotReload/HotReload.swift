import SwiftUI

// Hot reload for xtool apps on a real iPhone, driven from Linux by
// `ios-run --live`. In a view that should update live:
//
//     struct ContentView: View {
//         @ObserveHotReload private var hotReload
//         var body: some View {
//             ...
//             .hotReloadable()
//         }
//     }
//
// How it works (debug builds only; release builds get plain no-ops):
// - The app is linked with -interposable, so its calls to its own functions go
//   through pointer slots (__got / __la_symbol_ptr).
// - ios-run --live compiles each saved file into a signed hot-N.dylib and
//   pushes it into the app's Documents folder.
// - HotReloader (started by the first @ObserveHotReload) loads each new dylib
//   and points the app's slots for every function it redefines at the new code.
// - .hotReloadable() keeps body's type AnyView, so an edit that changes the
//   view tree still matches the type the running app was built with.
// - @ObserveHotReload makes the view re-run its (new) body after each swap.

/// Re-runs the view's body after each hot reload swap.
@MainActor
@propertyWrapper
public struct ObserveHotReload: DynamicProperty {
    #if DEBUG
    @ObservedObject private var observer = HotReloadObserver.shared
    #endif

    public init() {
        #if DEBUG
        HotReloader.start()
        #endif
    }

    /// How many swaps have happened (0 in release builds).
    public var wrappedValue: Int {
        #if DEBUG
        observer.generation
        #else
        0
        #endif
    }
}

extension View {
    /// Ends a view body that should update live. In debug builds it wraps the
    /// view in AnyView so the body's type stays the same across edits.
    public func hotReloadable() -> some View {
        #if DEBUG
        AnyView(self)
        #else
        self
        #endif
    }
}

#if DEBUG
import Foundation
import MachO
import Darwin

@MainActor
final class HotReloadObserver: ObservableObject {
    static let shared = HotReloadObserver()
    @Published var generation = 0
}

public enum HotReloader {
    private static let queue = DispatchQueue(label: "hotreload")
    nonisolated(unsafe) private static var timer: DispatchSourceTimer?
    nonisolated(unsafe) private static var handled: Set<String> = []
    nonisolated(unsafe) private static var attempts: [String: Int] = [:]
    // Symbol -> the address the app's slots point at now (original or last swap).
    nonisolated(unsafe) private static var current: [String: UInt] = [:]
    /// Starts watching for swaps. Cheap and safe to call any number of times
    /// (a static let initializer runs once, thread-safely).
    public static func start() {
        _ = startOnce
    }

    private static let startOnce: Void = {
        // Swaps from an earlier run belong to an older build: drop them.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        for name in names where isSwapFile(name) {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: 0.1)
        t.setEventHandler { scan() }
        t.resume()
        timer = t
        log("ready (module \(appModule))")
    }()

    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static var appModule: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? ""
    }

    private static func isSwapFile(_ name: String) -> Bool {
        name.hasPrefix("hot-") && name.hasSuffix(".dylib") && number(name) >= 0
    }

    private static func number(_ name: String) -> Int {
        Int(name.dropFirst("hot-".count).dropLast(".dylib".count)) ?? -1
    }

    private static func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        let fresh = names.filter { isSwapFile($0) && !handled.contains($0) }.sorted { number($0) < number($1) }
        for name in fresh { load(name) }
    }

    // Only the app's own code: symbols of its module, and extensions it
    // declares on other types ("<len><Module>E" in the mangled name).
    private static func isAppSymbol(_ symbol: String) -> Bool {
        let module = appModule
        guard !module.isEmpty else { return symbol.hasPrefix("$s") }
        let mangled = "\(module.utf8.count)\(module)"
        return symbol.hasPrefix("$s" + mangled) || (symbol.hasPrefix("$s") && symbol.contains(mangled + "E"))
    }

    // Accessors for state and type identity stay the app's: swapping them
    // would hand the app a second copy of a static's storage (split state) or
    // a type's metadata (`x is T` false for values made before the swap).
    // unsafeMutableAddressor (vau), global/static lazy initialisers (WZ, Wz),
    // metadata accessor / instantiation / completion (Ma, Mi, Mr).
    private static let keepSuffixes = ["vau", "WZ", "Wz", "Ma", "Mi", "Mr"]

    private static func isStateOrTypeAccessor(_ symbol: String) -> Bool {
        keepSuffixes.contains { symbol.hasSuffix($0) }
    }

    private static func load(_ name: String) {
        let path = documents.appendingPathComponent(name).path
        guard dlopen(path, RTLD_NOW) != nil else {
            // A push may still be writing the file: retry a few times.
            attempts[name, default: 0] += 1
            let error = String(cString: dlerror())
            if attempts[name]! >= 4 {
                handled.insert(name)
                log("\(name): couldn't load it: \(error)")
                log("SWAP FAILED: rerun the app normally")
            }
            return
        }
        handled.insert(name)
        guard let newImage = image(named: "/" + name), let app = mainExecutable() else {
            log("\(name): loaded, but couldn't find the images")
            return
        }
        // A function returning `some T` (a view helper, or a body without
        // .hotReloadable()) has a concrete return type fixed when the app was
        // built. If the edit changed it, old callers would misread the new
        // value (lost modifiers, or memory corruption). Refuse the whole swap;
        // ios-run --live sees SWAP REFUSED and runs the app again.
        let (checked, changed) = changedOpaqueTypes(app: app, new: newImage)
        if !changed.isEmpty {
            log("SWAP REFUSED \(name): the type returned by \(changed.prefix(3).joined(separator: ", ")) changed; needs a normal run")
            return
        }
        let appFunctions = functions(in: app)
        var swaps: [(symbol: String, original: UInt, from: UInt, to: UInt)] = []
        var newOnly = 0
        for (symbol, address) in functions(in: newImage) where isAppSymbol(symbol) {
            guard let original = appFunctions[symbol] else { newOnly += 1; continue }
            // The dylib is linked -interposable and -flat_namespace, so dyld
            // bound its own slots to the app's definitions (the app comes first
            // in the flat search). For state/type accessors that's what we want.
            guard !isStateOrTypeAccessor(symbol) else { continue }
            swaps.append((symbol, original, current[symbol] ?? original, address))
        }
        // The app: every pointer to the current version moves to the new one:
        // call slots (__got...), and also class vtables, protocol witness
        // tables and other function pointers in its data, so methods of
        // non-final classes and protocol calls swap too.
        let appCounts = repoint(in: app.header, everyDataSection: true,
                                mapping: Dictionary(swaps.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a }))
        // The dylib's own slots (bound to the app's originals) move to the new
        // code too, so new code calls new code.
        _ = repoint(in: newImage.header, everyDataSection: false,
                    mapping: Dictionary(swaps.map { ($0.original, $0.to) }, uniquingKeysWith: { a, _ in a }))
        var rewritten = 0
        for swap in swaps {
            let n = appCounts[swap.from] ?? 0
            // Functions with no pointer in the app (never called through one)
            // still count: other new code reaches them through the dylib.
            current[swap.symbol] = n > 0 ? swap.to : swap.from
            rewritten += n
        }
        let swapped = swaps.count
        log("swapped \(name): \(swapped) function(s), \(rewritten) pointer(s) repointed" +
            (newOnly > 0 ? ", \(newOnly) new" : "") + ", \(checked) return type(s) checked")
        Task { @MainActor in HotReloadObserver.shared.generation += 1 }
    }

    // MARK: Mach-O helpers

    private struct Image {
        let header: UnsafePointer<mach_header_64>
        let slide: Int
    }

    private static func image(named suffix: String) -> Image? {
        for i in 0..<_dyld_image_count() {
            guard let name = _dyld_get_image_name(i), String(cString: name).hasSuffix(suffix),
                  let header = _dyld_get_image_header(i) else { continue }
            return Image(header: UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self),
                         slide: _dyld_get_image_vmaddr_slide(i))
        }
        return nil
    }

    private static func mainExecutable() -> Image? {
        for i in 0..<_dyld_image_count() {
            guard let header = _dyld_get_image_header(i), header.pointee.filetype == UInt32(MH_EXECUTE) else { continue }
            return Image(header: UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self),
                         slide: _dyld_get_image_vmaddr_slide(i))
        }
        return nil
    }

    private static func segmentName(_ seg: UnsafePointer<segment_command_64>) -> String {
        withUnsafeBytes(of: seg.pointee.segname) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    // Opaque result type descriptors (`$s…QOMQ`) both images define, checked
    // by asking the Swift runtime for the underlying type of each: the same
    // type gives the same (uniqued) metadata pointer.
    // Only descriptors whose single generic parameter is the opaque type
    // itself (a `some T` from a non-generic function or property, like a view
    // body or helper) can be asked without arguments; others are skipped.
    // Layout (ABI): UInt32 flags (kind in bits 0-4, 4 = opaque type; bit 7 =
    // generic), Int32 parent, then if generic UInt16 NumParams, ...
    private static func checkable(_ desc: UnsafeRawPointer) -> Bool {
        let flags = desc.load(as: UInt32.self)
        guard flags & 0x1f == 4 else { return false }
        guard flags & 0x80 != 0 else { return true }
        return desc.load(fromByteOffset: 8, as: UInt16.self) == 1
    }

    // The underlying type's mangled name from an opaque type descriptor,
    // made comparable between images: each symbolic reference (bytes 0x01
    // to 0x17 + a 4-byte relative offset; 0x18 to 0x1f + an 8-byte address)
    // is replaced by the name of what it points at (dladdr). 0x02 is the
    // indirect form (it points at a pointer). Layout after flags and parent,
    // when generic: the generic header (NumParams, NumRequirements,
    // NumKeyArguments, Flags as UInt16), NumParams one-byte parameter
    // descriptors padded to 4, NumRequirements 12-byte requirements; then
    // relative pointers to the underlying types' names (the count is in the
    // flags' top 16 bits). nil when the layout isn't one this understands
    // (header flags set: packs, values...).
    private static func underlyingTypeName(_ desc: UnsafeRawPointer) -> String? {
        let flags = desc.load(as: UInt32.self)
        guard flags & 0x1f == 4, flags >> 16 >= 1 else { return nil }
        var offset = 8
        if flags & 0x80 != 0 {
            let params = Int(desc.load(fromByteOffset: 8, as: UInt16.self))
            let requirements = Int(desc.load(fromByteOffset: 10, as: UInt16.self))
            guard desc.load(fromByteOffset: 14, as: UInt16.self) == 0 else { return nil }
            offset = 16 + ((params + 3) & ~3) + requirements * 12
        }
        let field = desc.advanced(by: offset)
        var p = field.advanced(by: Int(field.load(as: Int32.self))).assumingMemoryBound(to: UInt8.self)
        var out = ""
        var guardCount = 0
        while p.pointee != 0 {
            guardCount += 1
            if guardCount > 4096 { return nil }
            let b = p.pointee
            if b >= 0x01 && b <= 0x17 {
                let ref = UnsafeRawPointer(p + 1)
                var target = ref.advanced(by: Int(ref.loadUnaligned(as: Int32.self)))
                if b == 0x02 { target = target.load(as: UnsafeRawPointer.self) }
                out += "<\(b):\(symbolName(target))>"
                p += 5
            } else if b >= 0x18 && b <= 0x1f {
                let address = UnsafeRawPointer(p + 1).loadUnaligned(as: UInt.self)
                out += "<\(b):\(UnsafeRawPointer(bitPattern: address).map(symbolName) ?? "nil")>"
                p += 9
            } else {
                out.unicodeScalars.append(UnicodeScalar(b))
                p += 1
            }
        }
        return out
    }

    private static func symbolName(_ address: UnsafeRawPointer) -> String {
        var info = Dl_info()
        guard dladdr(address, &info) != 0, let name = info.dli_sname else { return "?" }
        let delta = Int(bitPattern: address) - Int(bitPattern: info.dli_saddr)
        return String(cString: name) + (delta == 0 ? "" : "+\(delta)")
    }

    private static func changedOpaqueTypes(app: Image, new: Image) -> (checked: Int, changed: [String]) {
        typealias GetOpaque = @convention(c) (Int, UnsafeRawPointer?, UnsafeRawPointer, UInt32) -> UnsafeRawPointer?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_getOpaqueTypeMetadata2") else {
            return (0, [])
        }
        let getOpaque = unsafeBitCast(sym, to: GetOpaque.self)
        let appDescriptors = symbols(in: app, textOnly: false).filter { $0.key.hasSuffix("QOMQ") }
        var checked = 0
        var changed: [String] = []
        for (symbol, newAddress) in symbols(in: new, textOnly: false) where symbol.hasSuffix("QOMQ") && isAppSymbol(symbol) {
            guard let appAddress = appDescriptors[symbol],
                  let appDesc = UnsafeRawPointer(bitPattern: appAddress),
                  let newDesc = UnsafeRawPointer(bitPattern: newAddress) else { continue }
            if checkable(appDesc) && checkable(newDesc) {
                checked += 1
                if getOpaque(0, nil, appDesc, 0) != getOpaque(0, nil, newDesc, 0) {
                    changed.append(symbol)
                }
            } else if let before = underlyingTypeName(appDesc), let after = underlyingTypeName(newDesc) {
                // Generic functions or types: compare the underlying type's
                // mangled name instead (it uses placeholders for the generic
                // parameters, so it needs no arguments).
                checked += 1
                if before != after { changed.append(symbol) }
            }
        }
        return (checked, changed)
    }

    // Function symbols (in __TEXT,__text) of an image: name without the
    // leading underscore -> address in memory.
    private static func functions(in image: Image) -> [String: UInt] {
        symbols(in: image, textOnly: true)
    }

    // Symbols defined in an image's sections (only __TEXT,__text with
    // textOnly): name without the leading underscore -> address in memory.
    private static func symbols(in image: Image, textOnly: Bool) -> [String: UInt] {
        var symtab: UnsafePointer<symtab_command>?
        var linkedit: UnsafePointer<segment_command_64>?
        var cmd = UnsafeRawPointer(image.header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<image.header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self)
            if lc.pointee.cmd == UInt32(LC_SYMTAB) {
                symtab = cmd.assumingMemoryBound(to: symtab_command.self)
            } else if lc.pointee.cmd == UInt32(LC_SEGMENT_64) {
                let seg = cmd.assumingMemoryBound(to: segment_command_64.self)
                if segmentName(seg) == "__LINKEDIT" { linkedit = seg }
            }
            cmd = cmd.advanced(by: Int(lc.pointee.cmdsize))
        }
        guard let symtab, let linkedit else { return [:] }
        let base = Int(linkedit.pointee.vmaddr) - Int(linkedit.pointee.fileoff) + image.slide
        guard let syms = UnsafePointer<nlist_64>(bitPattern: base + Int(symtab.pointee.symoff)),
              let strings = UnsafePointer<CChar>(bitPattern: base + Int(symtab.pointee.stroff)) else { return [:] }
        var textSize: UInt = 0
        guard let text = getsectiondata(image.header, "__TEXT", "__text", &textSize) else { return [:] }
        let textRange = UInt(bitPattern: text)..<(UInt(bitPattern: text) + textSize)
        var out: [String: UInt] = [:]
        for i in 0..<Int(symtab.pointee.nsyms) {
            let s = syms[i]
            // Skip debug (stab) entries; keep symbols defined in a section.
            guard s.n_type & 0xe0 == 0, s.n_type & 0x0e == 0x0e, s.n_un.n_strx > 0 else { continue }
            let address = UInt(Int(s.n_value) + image.slide)
            guard !textOnly || textRange.contains(address) else { continue }
            var name = String(cString: strings.advanced(by: Int(s.n_un.n_strx)))
            if name.hasPrefix("_") { name.removeFirst() }
            out[name] = address
        }
        return out
    }

    // Rewrite pointers in an image's data: every 8-byte value that is a key
    // of `mapping` becomes its value. With everyDataSection, all sections of
    // the data segments are scanned (call slots, class vtables, witness
    // tables, other function pointers); otherwise only the call slot
    // sections. Returns how many pointers each old address had.
    private static func repoint(in header: UnsafePointer<mach_header_64>, everyDataSection: Bool,
                                mapping: [UInt: UInt]) -> [UInt: Int] {
        var counts: [UInt: Int] = [:]
        guard !mapping.isEmpty else { return counts }
        let pageSize = UInt(getpagesize())
        let segments: Set<String> = ["__DATA_CONST", "__DATA", "__AUTH_CONST", "__AUTH"]
        let slotSections: Set<String> = ["__got", "__la_symbol_ptr", "__auth_got"]
        var lastPage: UInt = 0
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.assumingMemoryBound(to: load_command.self)
            defer { cmd = cmd.advanced(by: Int(lc.pointee.cmdsize)) }
            guard lc.pointee.cmd == UInt32(LC_SEGMENT_64) else { continue }
            let seg = cmd.assumingMemoryBound(to: segment_command_64.self)
            let segName = segmentName(seg)
            guard segments.contains(segName) else { continue }
            var sectionPtr = cmd.advanced(by: MemoryLayout<segment_command_64>.size)
                .assumingMemoryBound(to: section_64.self)
            for _ in 0..<seg.pointee.nsects {
                defer { sectionPtr += 1 }
                let sectName = withUnsafeBytes(of: sectionPtr.pointee.sectname) { raw in
                    String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
                }
                guard everyDataSection || slotSections.contains(sectName) else { continue }
                var size: UInt = 0
                guard let start = getsectiondata(header, segName, sectName, &size), size >= 8 else { continue }
                // Zero-fill sections (bss, common) hold no pointers yet.
                let type = sectionPtr.pointee.flags & 0xff
                if type == 0x1 || type == 0xc { continue }  // S_ZEROFILL, S_GB_ZEROFILL
                let words = UnsafeMutableRawPointer(start).bindMemory(to: UInt.self, capacity: Int(size) / 8)
                for i in 0..<(Int(size) / 8) {
                    guard let to = mapping[words[i]] else { continue }
                    // __DATA_CONST is read-only after launch: make the page writable.
                    let page = UInt(bitPattern: words + i) & ~(pageSize - 1)
                    if page != lastPage {
                        vm_protect(mach_task_self_, vm_address_t(page), vm_size_t(pageSize), 0,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY)
                        lastPage = page
                    }
                    counts[words[i], default: 0] += 1
                    words[i] = to
                }
            }
        }
        return counts
    }

    private static func log(_ s: String) {
        print("hotreload: " + s)
    }
}
#endif
