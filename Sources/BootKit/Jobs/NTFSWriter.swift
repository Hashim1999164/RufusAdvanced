import Foundation

/// Writes an image's files to an NTFS partition through the embedded ntfs-3g (no mount, no macFUSE).
///
/// NTFS can't be mounted read/write on macOS, so files that the OS specific setup modifies are first
/// prepared in an *overlay* folder (copies of the touched files + new files). The ISO tree and the
/// overlay are then merged and written to the volume in a single pass; overlay files win.
public final class NTFSWriter {
    public struct Entry {
        public var rel: String          // "/sources/install.wim" (case as on the image)
        public var local: String        // file to read
        public var size: UInt64
        public var isDirectory: Bool
    }

    let source: String
    public let overlay: String
    let skip: Set<String>

    public init(source: String, scratch: String, skip: Set<String> = []) throws {
        self.source = source
        overlay = scratch + "/ntfs-overlay"
        self.skip = skip
        try? FileManager.default.removeItem(atPath: overlay)
        try FileManager.default.createDirectory(atPath: overlay, withIntermediateDirectories: true)
    }

    // MARK: Overlay

    /// Copy a file of the image into the overlay (keeping the image's letter case) so it can be modified.
    @discardableResult
    public func stage(_ rel: String) -> Bool {
        guard let real = SyslinuxInstaller.resolveCase(rel, root: source) else { return false }
        let dst = overlay + real
        if FileManager.default.fileExists(atPath: dst) { return true }
        try? FileManager.default.createDirectory(atPath: (dst as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        do {
            try FileManager.default.copyItem(atPath: source + real, toPath: dst)
            // Images are read-only: make the staged copy writable.
            _ = chmod(dst, 0o644)
            return true
        } catch {
            logWarning("Could not stage \(real): \(error.localizedDescription)")
            return false
        }
    }

    /// Stage every boot loader configuration file that LinuxSetup may patch.
    public func stageLinuxConfigs(_ image: ImageReport) {
        for rel in image.syslinuxConfigs + image.grubConfigs { stage(rel) }
        for dir in ["/loader/entries", "/boot/grub", "/boot/grub2", "/efi/boot", "/isolinux", "/syslinux", "/boot/isolinux", "/boot/syslinux"] {
            guard let real = SyslinuxInstaller.resolveCase(dir, root: source),
                  let items = try? FileManager.default.contentsOfDirectory(atPath: source + real) else { continue }
            for i in items where i.lowercased().hasSuffix(".cfg") || i.lowercased().hasSuffix(".conf") { stage(real + "/" + i) }
        }
    }

    // MARK: Merge

    /// The merged view (image + overlay), directories first, in a stable order.
    public func entries() -> [Entry] {
        var map: [String: Entry] = [:]
        func walk(_ root: String, isOverlay: Bool) {
            guard let e = FileManager.default.enumerator(atPath: root) else { return }
            while let relRaw = e.nextObject() as? String {
                let rel = "/" + relRaw
                let key = rel.lowercased()
                let a = e.fileAttributes ?? [:]
                var type = a[.type] as? FileAttributeType
                var size = (a[.size] as? NSNumber)?.uint64Value ?? 0
                var local = root + rel
                if !isOverlay && skip.contains(key) {
                    if type == .typeDirectory { e.skipDescendants() }
                    continue
                }
                if type == .typeSymbolicLink {
                    // NTFS (from Windows' point of view) can't hold these links: store the file they point to.
                    let resolved = URL(fileURLWithPath: local).resolvingSymlinksInPath().path
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), !isDir.boolValue else {
                        logWarning("Skipped symbolic link \(rel)")
                        continue
                    }
                    local = resolved
                    type = .typeRegular
                    size = (try? FileManager.default.attributesOfItem(atPath: resolved)[.size] as? UInt64) ?? 0
                }
                let isDir = type == .typeDirectory
                guard isDir || type == .typeRegular else { continue }
                // Keep the image's spelling of existing names.
                let display = map[key]?.rel ?? rel
                map[key] = Entry(rel: display, local: local, size: size, isDirectory: isDir)
            }
        }
        walk(source, isOverlay: false)
        walk(overlay, isOverlay: true)
        return map.values.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.rel.lowercased() < $1.rel.lowercased()
        }
    }

    // MARK: UEFI media validation on the overlay

    /// uefi-md5sum in front of the EFI loaders + md5sum.txt over the merged view.
    public func installUEFIMediaValidation(reporter: JobReporter, cancel: CancellationToken) throws {
        var installed: [String] = []
        let all = entries()
        for arch in ["x64", "ia32", "aa64", "arm", "riscv64", "loongarch64"] {
            guard let entry = all.first(where: { $0.rel.lowercased() == "/efi/boot/boot\(arch).efi" }),
                  let loader = try? BootResources.data("uefi-md5sum/boot\(arch).efi") else { continue }
            let dir = (entry.rel as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: overlay + dir, withIntermediateDirectories: true)
            let original = overlay + dir + "/boot\(arch)_original.efi"
            try? FileManager.default.removeItem(atPath: original)
            try FileManager.default.copyItem(atPath: entry.local, toPath: original)
            try? FileManager.default.removeItem(atPath: overlay + entry.rel)
            try loader.write(to: URL(fileURLWithPath: overlay + entry.rel))
            installed.append(entry.rel.lowercased())
        }
        guard !installed.isEmpty else { logWarning("No EFI boot loader found: UEFI media validation skipped"); return }
        reporter.begin("Computing MD5 checksums for UEFI media validation")
        let skipped = Set(installed + ["/md5sum.txt", "/autorun.inf", "/autorun.ico"])
        let files = entries().filter { !$0.isDirectory && !skipped.contains($0.rel.lowercased()) }
        let grand = files.reduce(0) { $0 + $1.size }
        var done: UInt64 = 0
        var lines: [String] = []
        for f in files {
            try cancel.check()
            let h = try MultiHasher.hashFile(at: f.local, algorithms: [.md5], cancel: cancel) { p in
                reporter.bytes(done + UInt64(Double(f.size) * p), of: grand, detail: (f.rel as NSString).lastPathComponent)
            }
            done += f.size
            lines.append("\(h[.md5] ?? "")  .\(f.rel)")
        }
        let text = "# md5sum_totalbytes = 0x\(String(grand, radix: 16))\n" + lines.joined(separator: "\n") + "\n"
        try text.write(toFile: overlay + "/md5sum.txt", atomically: false, encoding: .utf8)
        logInfo("Installed uefi-md5sum for \(installed.joined(separator: ", ")) and wrote md5sum.txt (\(lines.count) files)")
    }

    // MARK: Write

    // MARK: Finalize

    /// Close the volume and flush the drive with visible progress: writing back cached metadata is
    /// measured in bytes, flushing the drive's own cache is shown with the elapsed time (both can
    /// take minutes on slow USB drives).
    public static func finalize(_ vol: NTFSVolume, device dev: RawDevice, reporter r: JobReporter) throws {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var text = "Writing NTFS metadata"
            var done: UInt64 = 0, total: UInt64 = 0
            var loggedMetadata = false, loggedDevice = false
        }
        let st = State()
        let start = Date()
        r.begin("Finalizing", detail: "Writing NTFS metadata")
        logInfo("Finalizing NTFS: writing the remaining metadata, then flushing the drive (slow USB drives can take a few minutes)")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        var lastLog = start
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler {
            st.lock.lock(); let text = st.text, done = st.done, total = st.total; st.lock.unlock()
            let elapsed = Units.duration(Date().timeIntervalSince(start))
            if total > 0 {
                r.update(fraction: Double(done) / Double(total), detail: "\(text) · \(elapsed)", bytesDone: done, bytesTotal: total, force: true)
            } else {
                r.update(fraction: nil, detail: "\(text) · \(elapsed)", force: true)
            }
            if Date().timeIntervalSince(lastLog) >= 10 {
                lastLog = Date()
                logDebug("  Still finalizing: \(text)\(total > 0 ? " (\(Units.human(done)) of \(Units.human(total)))" : "") — \(elapsed) so far")
            }
        }
        timer.resume()
        defer { timer.cancel() }

        try vol.close { stage, done, total in
            st.lock.lock()
            var line: String?
            if stage == 0 {
                st.text = "Writing NTFS metadata"
                st.done = done; st.total = total
                if !st.loggedMetadata { st.loggedMetadata = true; line = "Writing \(Units.human(total)) of cached NTFS metadata to the drive" }
            } else {
                st.text = "Flushing the drive's write cache"
                st.done = 0; st.total = 0
                if !st.loggedDevice { st.loggedDevice = true; line = "Flushing the drive's write cache (the drive confirms everything is stored)" }
            }
            st.lock.unlock()
            if let line { logInfo(line) }
        }
        st.lock.lock(); st.text = "Flushing the drive's write cache"; st.done = 0; st.total = 0; st.lock.unlock()
        dev.sync()
        logInfo("NTFS volume finalized in \(Units.duration(Date().timeIntervalSince(start)))")
    }

    /// Files below this size are written before the large ones (see `write`).
    static let smallFileLimit: UInt64 = 4 * Units.MB

    /// FAT/NTFS-safe name for Windows (no * ? : " < > | and no trailing dot or space).
    static func windowsSafe(_ rel: String) -> String {
        let bad = CharacterSet(charactersIn: "\"*:<>?\\|").union(.controlCharacters)
        return rel.split(separator: "/").map { comp -> String in
            var s = String(String.UnicodeScalarView(comp.unicodeScalars.map { bad.contains($0) ? "_" : $0 }))
            while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
            return s.isEmpty ? "_" : s
        }.reduce("") { $0 + "/" + $1 }
    }

    /// Write the merged view to the NTFS volume.
    public func write(to vol: NTFSVolume, reporter: JobReporter, cancel: CancellationToken) throws {
        var list = entries()
        // Small files first (directories are already first): NTFS allocates space in write order, so
        // this keeps the many small files next to each other instead of scattered between the large
        // ones. Flash drives write neighbouring data far faster than scattered small pieces.
        // RUFUS_NTFS_PATH_ORDER=1 keeps plain path order (measurements).
        if ProcessInfo.processInfo.environment["RUFUS_NTFS_PATH_ORDER"] == nil {
            let small = Self.smallFileLimit
            list = list.filter(\.isDirectory) + list.filter { !$0.isDirectory && $0.size < small }
                + list.filter { !$0.isDirectory && $0.size >= small }
        }
        let total = list.filter { !$0.isDirectory }.reduce(0) { $0 + $1.size }
        reporter.begin("Copying files", detail: "NTFS (embedded ntfs-3g)", total: total)
        var done: UInt64 = 0
        var renamed = 0
        for e in list {
            try cancel.check()
            let dest = Self.windowsSafe(e.rel)
            if dest != e.rel { renamed += 1 }
            if e.isDirectory {
                try vol.mkdir(dest)
                continue
            }
            let name = (e.rel as NSString).lastPathComponent
            try vol.writeFile(dest, from: e.local, cancel: cancel) { n in
                done += n
                reporter.bytes(done, of: total, detail: name)
            }
        }
        if renamed > 0 { logWarning("\(renamed) name(s) contained characters Windows doesn't allow and were adjusted") }
        let space = vol.space
        logInfo("Copied \(Units.human(total)) to NTFS (\(Units.human(space.free)) free of \(Units.human(space.total)))")
    }
}
