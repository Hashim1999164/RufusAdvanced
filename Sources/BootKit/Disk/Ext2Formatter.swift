import Foundation

/// Minimal, self-contained ext2/ext3 formatter (no e2fsprogs needed).
///
/// Produces a revision 1 file system with sparse superblocks, file types in directory
/// entries, large files, 256 byte inodes and uninit_bg group descriptor checksums so the
/// (huge) inode tables don't need to be zeroed. ext3 adds an internal JBD2 journal (inode 8).
/// Small files (e.g. `persistence.conf`) can be created in the root directory.
public struct Ext2Formatter {
    public struct File {
        public var name: String
        public var contents: Data
        public init(name: String, contents: Data) { self.name = name; self.contents = contents }
    }

    public var label: String
    public var journal: Bool
    public var blockSize: UInt32
    public var inodeRatio: UInt64 = 65536
    public var reservedPercent: Double = 0
    public var files: [File] = []
    public var uuid = UUID()

    public init(label: String, journal: Bool, partitionSize: UInt64, blockSize: UInt32? = nil) {
        self.label = label
        self.journal = journal
        self.blockSize = blockSize ?? (partitionSize < 512 * Units.MB ? 1024 : 4096)
    }

    // Feature flags
    static let compatHasJournal: UInt32 = 0x0004
    static let compatExtAttr: UInt32 = 0x0008
    static let incompatFiletype: UInt32 = 0x0002
    static let roCompatSparseSuper: UInt32 = 0x0001
    static let roCompatLargeFile: UInt32 = 0x0002
    static let roCompatGdtCsum: UInt32 = 0x0010

    static let bgInodeUninit: UInt16 = 0x0001
    static let bgInodeZeroed: UInt16 = 0x0004

    static let inodeSize = 256
    static let firstIno: UInt32 = 11
    static let rootIno: UInt32 = 2
    static let journalIno: UInt32 = 8
    static let lostFoundIno: UInt32 = 11

    static func isSparseGroup(_ g: Int) -> Bool {
        if g <= 1 { return true }
        for base in [3, 5, 7] {
            var p = base
            while p < g { p *= base }
            if p == g { return true }
        }
        return false
    }

    static func defaultJournalBlocks(_ blocks: UInt64) -> UInt64 {
        if blocks < 2048 { return 0 }
        if blocks < 32768 { return 1024 }
        if blocks < 256 * 1024 { return 4096 }
        if blocks < 512 * 1024 { return 8192 }
        if blocks < 4096 * 1024 { return 16384 }
        return 32768
    }

    /// Format the area [offset, offset+size) of `dev`.
    public func format(_ dev: RawDevice, offset: UInt64, size: UInt64, cancel: CancellationToken? = nil) throws {
        let B = UInt64(blockSize)
        let logBlock = UInt32(log2(Double(blockSize / 1024)))
        let firstDataBlock: UInt64 = B == 1024 ? 1 : 0
        let blocksPerGroup = 8 * B
        var blocksCount = size / B
        guard blocksCount >= 64 else { throw BootKitError.deviceTooSmall(needed: 64 * B, available: size) }

        let inodesPerBlock = B / UInt64(Self.inodeSize)
        var groupCount = Int((blocksCount - firstDataBlock + blocksPerGroup - 1) / blocksPerGroup)
        var inodesPerGroup = Units.alignUp(max(blocksPerGroup * B / inodeRatio, 16), inodesPerBlock)
        inodesPerGroup = min(inodesPerGroup, 8 * B)
        inodesPerGroup = Units.alignUp(inodesPerGroup, 8)
        var itableBlocks = inodesPerGroup / inodesPerBlock
        var gdtBlocks = UInt64((groupCount * 32 + Int(B) - 1) / Int(B))

        // Drop a runt last group (like mke2fs does).
        let overhead = { (g: Int) -> UInt64 in (Self.isSparseGroup(g) ? 1 + gdtBlocks : 0) + 2 + itableBlocks }
        let lastGroupBlocks = blocksCount - firstDataBlock - UInt64(groupCount - 1) * blocksPerGroup
        if groupCount > 1 && lastGroupBlocks < overhead(groupCount - 1) + 50 {
            groupCount -= 1
            blocksCount = firstDataBlock + UInt64(groupCount) * blocksPerGroup
            gdtBlocks = UInt64((groupCount * 32 + Int(B) - 1) / Int(B))
        }
        // Tiny file systems: one group, shrink inode count to fit.
        if groupCount == 1 {
            let avail = blocksCount - firstDataBlock
            while itableBlocks > 1 && overhead(0) + 64 > avail {
                inodesPerGroup = max(inodesPerBlock, inodesPerGroup / 2)
                itableBlocks = inodesPerGroup / inodesPerBlock
            }
        }
        let inodesCount = inodesPerGroup * UInt64(groupCount)

        // Block usage bitmap for the whole file system (true = used).
        var used = BitSet(count: Int(blocksCount))
        for b in 0..<Int(firstDataBlock) { used[b] = true }

        struct Group { var start: UInt64; var blocks: UInt64; var blockBitmap: UInt64; var inodeBitmap: UInt64; var inodeTable: UInt64; var hasSuper: Bool }
        var groups: [Group] = []
        for g in 0..<groupCount {
            let start = firstDataBlock + UInt64(g) * blocksPerGroup
            let blocks = min(blocksPerGroup, blocksCount - start)
            var cur = start
            let hasSuper = Self.isSparseGroup(g)
            if hasSuper { cur += 1 + gdtBlocks }
            let bb = cur, ib = cur + 1, it = cur + 2
            for b in start..<(it + itableBlocks) { used[Int(b)] = true }
            groups.append(Group(start: start, blocks: blocks, blockBitmap: bb, inodeBitmap: ib, inodeTable: it, hasSuper: hasSuper))
        }

        // Simple sequential allocator for data blocks.
        var nextFree = 0
        func alloc() throws -> UInt64 {
            while nextFree < used.count && used[nextFree] { nextFree += 1 }
            guard nextFree < used.count else { throw BootKitError.generic("ext2: out of space while formatting") }
            used[nextFree] = true
            return UInt64(nextFree)
        }

        let now = UInt32(Date().timeIntervalSince1970)
        var inodes: [UInt32: [UInt8]] = [:]
        var dataBlocks: [UInt64: [UInt8]] = [:]

        func makeInode(mode: UInt16, size: UInt64, links: UInt16, blocks: [UInt64], metaBlocks: Int = 0) -> [UInt8] {
            var i = [UInt8](repeating: 0, count: Self.inodeSize)
            LE.put16(&i, 0, mode)
            LE.put32(&i, 4, UInt32(size & 0xffff_ffff))
            LE.put32(&i, 8, now); LE.put32(&i, 12, now); LE.put32(&i, 16, now)
            LE.put16(&i, 26, links)
            LE.put32(&i, 28, UInt32((UInt64(blocks.count + metaBlocks) * B) / 512))
            for (k, b) in blocks.prefix(12).enumerated() { LE.put32(&i, 40 + 4 * k, UInt32(b)) }
            LE.put32(&i, 108, UInt32(size >> 32))
            LE.put16(&i, 128, 32) // i_extra_isize
            return i
        }

        func dirBlock(_ entries: [(UInt32, String, UInt8)]) -> [UInt8] {
            var d = [UInt8](repeating: 0, count: Int(B))
            var off = 0
            for (idx, e) in entries.enumerated() {
                let name = Array(e.1.utf8)
                var rec = (8 + name.count + 3) & ~3
                if idx == entries.count - 1 { rec = Int(B) - off }
                LE.put32(&d, off, e.0)
                LE.put16(&d, off + 4, UInt16(rec))
                d[off + 6] = UInt8(name.count)
                d[off + 7] = e.2
                d.replaceSubrange((off + 8)..<(off + 8 + name.count), with: name)
                off += rec
            }
            return d
        }

        // lost+found
        let lfBlock = try alloc()
        dataBlocks[lfBlock] = dirBlock([(Self.lostFoundIno, ".", 2), (Self.rootIno, "..", 2)])
        inodes[Self.lostFoundIno] = makeInode(mode: 0x41C0, size: B, links: 2, blocks: [lfBlock])

        // Files in the root directory.
        var rootEntries: [(UInt32, String, UInt8)] = [(Self.rootIno, ".", 2), (Self.rootIno, "..", 2), (Self.lostFoundIno, "lost+found", 2)]
        var nextIno = Self.firstIno + 1
        for f in files {
            let bytes = [UInt8](f.contents)
            guard bytes.count <= 12 * Int(B) else { throw BootKitError.generic("ext2: seed file too large") }
            var blocks: [UInt64] = []
            var off = 0
            while off < bytes.count {
                let b = try alloc()
                var chunk = [UInt8](repeating: 0, count: Int(B))
                let n = min(Int(B), bytes.count - off)
                chunk.replaceSubrange(0..<n, with: bytes[off..<(off + n)])
                dataBlocks[b] = chunk
                blocks.append(b)
                off += n
            }
            inodes[nextIno] = makeInode(mode: 0x81A4, size: UInt64(bytes.count), links: 1, blocks: blocks)
            rootEntries.append((nextIno, f.name, 1))
            nextIno += 1
        }
        let rootBlock = try alloc()
        dataBlocks[rootBlock] = dirBlock(rootEntries)
        inodes[Self.rootIno] = makeInode(mode: 0x41ED, size: B, links: 3, blocks: [rootBlock])

        // Journal (ext3)
        var journalBlockList: [UInt64] = []
        var journalInodeBlocks = [UInt32](repeating: 0, count: 15)
        if journal {
            let jBlocks = Self.defaultJournalBlocks(blocksCount)
            if jBlocks > 0 {
                let ptrsPerBlock = Int(B / 4)
                var meta: [UInt64: [UInt32]] = [:]   // indirect block -> pointers
                var direct: [UInt64] = []
                var ind: UInt64 = 0
                var dind: UInt64 = 0
                var curInd: UInt64 = 0
                for k in 0..<Int(jBlocks) {
                    if k == 12 { ind = try alloc(); meta[ind] = [] }
                    if k == 12 + ptrsPerBlock { dind = try alloc(); meta[dind] = [] }
                    if k >= 12 + ptrsPerBlock && (k - 12 - ptrsPerBlock) % ptrsPerBlock == 0 {
                        curInd = try alloc(); meta[curInd] = []
                        meta[dind]!.append(UInt32(curInd))
                    }
                    let b = try alloc()
                    journalBlockList.append(b)
                    if k < 12 { direct.append(b) }
                    else if k < 12 + ptrsPerBlock { meta[ind]!.append(UInt32(b)) }
                    else { meta[curInd]!.append(UInt32(b)) }
                }
                guard Int(jBlocks) <= 12 + ptrsPerBlock + ptrsPerBlock * ptrsPerBlock else {
                    throw BootKitError.generic("ext3: journal too large")
                }
                for (blk, ptrs) in meta {
                    var d = [UInt8](repeating: 0, count: Int(B))
                    for (k, p) in ptrs.enumerated() { LE.put32(&d, 4 * k, p) }
                    dataBlocks[blk] = d
                }
                var jinode = makeInode(mode: 0x8180, size: jBlocks * B, links: 1, blocks: direct, metaBlocks: meta.count)
                LE.put32(&jinode, 28, UInt32((jBlocks + UInt64(meta.count)) * B / 512))
                if ind != 0 { LE.put32(&jinode, 40 + 4 * 12, UInt32(ind)) }
                if dind != 0 { LE.put32(&jinode, 40 + 4 * 13, UInt32(dind)) }
                for k in 0..<15 { journalInodeBlocks[k] = LE.get32(jinode, 40 + 4 * k) }
                inodes[Self.journalIno] = jinode

                // JBD2 superblock (big endian) in the first journal block.
                var js = [UInt8](repeating: 0, count: Int(B))
                func be32(_ off: Int, _ v: UInt32) { for i in 0..<4 { js[off + i] = UInt8((v >> (24 - 8 * UInt32(i))) & 0xff) } }
                be32(0, 0xC03B_3998)
                be32(4, 4)                 // JBD2_SUPERBLOCK_V2
                be32(8, 0)
                be32(12, blockSize)
                be32(16, UInt32(jBlocks))
                be32(20, 1)                // s_first
                be32(24, 1)                // s_sequence
                be32(28, 0)                // s_start: clean journal
                js.replaceSubrange(48..<64, with: uuidBytes)
                be32(64, 1)                // nr_users
                js.replaceSubrange(256..<272, with: uuidBytes)
                dataBlocks[journalBlockList[0]] = js
            }
        }

        // Inode 1..10 are reserved; mark used inodes.
        var usedInodes = Set<UInt32>(1...Self.firstIno - 1)
        usedInodes.formUnion(inodes.keys)
        let maxUsedIno = usedInodes.max() ?? Self.firstIno
        guard UInt64(maxUsedIno) <= inodesPerGroup else { throw BootKitError.generic("ext2: too few inodes in group 0") }

        // Free counts
        var freeBlocksTotal: UInt64 = 0
        var groupFreeBlocks: [UInt64] = []
        for g in groups {
            var free: UInt64 = 0
            for b in g.start..<(g.start + g.blocks) where !used[Int(b)] { free += 1 }
            groupFreeBlocks.append(free)
            freeBlocksTotal += free
        }
        let freeInodesTotal = inodesCount - UInt64(usedInodes.count)

        // Superblock
        var sb = [UInt8](repeating: 0, count: 1024)
        LE.put32(&sb, 0, UInt32(inodesCount))
        LE.put32(&sb, 4, UInt32(blocksCount))
        LE.put32(&sb, 8, UInt32(Double(blocksCount) * reservedPercent / 100))
        LE.put32(&sb, 12, UInt32(freeBlocksTotal))
        LE.put32(&sb, 16, UInt32(freeInodesTotal))
        LE.put32(&sb, 20, UInt32(firstDataBlock))
        LE.put32(&sb, 24, logBlock)
        LE.put32(&sb, 28, logBlock)
        LE.put32(&sb, 32, UInt32(blocksPerGroup))
        LE.put32(&sb, 36, UInt32(blocksPerGroup))
        LE.put32(&sb, 40, UInt32(inodesPerGroup))
        LE.put32(&sb, 48, now)
        LE.put16(&sb, 52, 0)
        LE.put16(&sb, 54, 0xFFFF)          // max mount count: -1
        LE.put16(&sb, 56, 0xEF53)
        LE.put16(&sb, 58, 1)               // clean
        LE.put16(&sb, 60, 1)               // errors: continue
        LE.put32(&sb, 64, now)
        LE.put32(&sb, 76, 1)               // dynamic rev
        LE.put32(&sb, 84, Self.firstIno)
        LE.put16(&sb, 88, UInt16(Self.inodeSize))
        LE.put32(&sb, 92, Self.compatExtAttr | (journal && !journalBlockList.isEmpty ? Self.compatHasJournal : 0))
        LE.put32(&sb, 96, Self.incompatFiletype)
        LE.put32(&sb, 100, Self.roCompatSparseSuper | Self.roCompatLargeFile | Self.roCompatGdtCsum)
        sb.replaceSubrange(104..<120, with: uuidBytes)
        let lbl = Array(label.utf8.prefix(16))
        sb.replaceSubrange(120..<(120 + lbl.count), with: lbl)
        if journal && !journalBlockList.isEmpty {
            LE.put32(&sb, 224, Self.journalIno)
            sb[253] = 1                    // EXT3_JNL_BACKUP_BLOCKS
            for k in 0..<15 { LE.put32(&sb, 268 + 4 * k, journalInodeBlocks[k]) }
            let jsize = UInt64(journalBlockList.count) * B
            LE.put32(&sb, 268 + 4 * 15, UInt32(jsize >> 32))
            LE.put32(&sb, 268 + 4 * 16, UInt32(jsize & 0xffff_ffff))
        }
        for k in 0..<4 { LE.put32(&sb, 236 + 4 * k, UInt32.random(in: 0...UInt32.max)) }
        sb[252] = 1                        // half_md4
        LE.put32(&sb, 264, now)
        LE.put16(&sb, 348, 32)             // s_min_extra_isize
        LE.put16(&sb, 350, 32)             // s_want_extra_isize

        // Group descriptors
        var gdt = [UInt8](repeating: 0, count: Int(gdtBlocks * B))
        for (gi, g) in groups.enumerated() {
            let o = gi * 32
            LE.put32(&gdt, o, UInt32(g.blockBitmap))
            LE.put32(&gdt, o + 4, UInt32(g.inodeBitmap))
            LE.put32(&gdt, o + 8, UInt32(g.inodeTable))
            LE.put16(&gdt, o + 12, UInt16(groupFreeBlocks[gi]))
            if gi == 0 {
                LE.put16(&gdt, o + 14, UInt16(inodesPerGroup - UInt64(usedInodes.count)))
                LE.put16(&gdt, o + 16, 2)
                LE.put16(&gdt, o + 18, Self.bgInodeZeroed)
                LE.put16(&gdt, o + 28, UInt16(inodesPerGroup - UInt64(maxUsedIno)))
            } else {
                LE.put16(&gdt, o + 14, UInt16(inodesPerGroup))
                LE.put16(&gdt, o + 18, Self.bgInodeUninit)
                LE.put16(&gdt, o + 28, UInt16(inodesPerGroup))
            }
            var desc = Array(gdt[o..<(o + 32)])
            LE.put16(&desc, 30, 0)
            LE.put16(&gdt, o + 30, groupChecksum(group: UInt32(gi), desc: desc))
        }

        // ---- Write everything ----
        func writeBlock(_ blk: UInt64, _ data: [UInt8]) throws {
            try dev.writeBytes(at: offset + blk * B, data)
        }
        // Zero the boot area (first 1 KiB is boot code space, may contain stale data).
        try dev.zero(at: offset, count: max(B * (firstDataBlock + 1), 4096))

        for (gi, g) in groups.enumerated() {
            try cancel?.check()
            if g.hasSuper {
                var copy = sb
                LE.put16(&copy, 90, UInt16(gi))
                if gi == 0 {
                    try dev.writeBytes(at: offset + 1024, copy)
                } else {
                    try writeBlock(g.start, copy + [UInt8](repeating: 0, count: Int(B) - 1024))
                }
                try writeBlock(g.start + 1, gdt)
            }
            // Block bitmap
            var bb = [UInt8](repeating: 0, count: Int(B))
            for k in 0..<Int(blocksPerGroup) {
                let blk = g.start + UInt64(k)
                let isUsed = k >= Int(g.blocks) || blk >= blocksCount || used[Int(blk)]
                if isUsed { bb[k / 8] |= UInt8(1 << (k % 8)) }
            }
            try writeBlock(g.blockBitmap, bb)
            // Inode bitmap
            var ib = [UInt8](repeating: 0, count: Int(B))
            for k in 0..<Int(8 * B) {
                let ino = UInt32(gi) * UInt32(inodesPerGroup) + UInt32(k) + 1
                if k >= Int(inodesPerGroup) || (gi == 0 && usedInodes.contains(ino)) { ib[k / 8] |= UInt8(1 << (k % 8)) }
            }
            try writeBlock(g.inodeBitmap, ib)
        }

        // Group 0 inode table: zero it, then write the used inodes.
        try dev.zero(at: offset + groups[0].inodeTable * B, count: itableBlocks * B)
        for (ino, data) in inodes {
            let idx = UInt64(ino - 1)
            try dev.writeBytes(at: offset + groups[0].inodeTable * B + idx * UInt64(Self.inodeSize), data)
        }

        // Journal blocks must be zeroed (stale data would be replayed otherwise).
        if !journalBlockList.isEmpty {
            var run: [UInt64] = []
            func flushRun() throws {
                guard let first = run.first else { return }
                try dev.zero(at: offset + first * B, count: UInt64(run.count) * B)
                run.removeAll()
            }
            for b in journalBlockList {
                try cancel?.check()
                if let last = run.last, b != last + 1 { try flushRun() }
                run.append(b)
            }
            try flushRun()
        }
        for (blk, data) in dataBlocks { try writeBlock(blk, data) }
        dev.sync()
        logInfo("Created \(journal ? "ext3" : "ext2") file system '\(label)': \(Units.human(blocksCount * B)), \(groupCount) groups, \(inodesCount) inodes")
    }

    /// Compact bit array (one bit per block).
    struct BitSet {
        private var words: [UInt64]
        let count: Int
        init(count: Int) { self.count = count; words = [UInt64](repeating: 0, count: (count + 63) / 64) }
        subscript(i: Int) -> Bool {
            get { (words[i >> 6] >> UInt64(i & 63)) & 1 == 1 }
            set {
                if newValue { words[i >> 6] |= (1 << UInt64(i & 63)) } else { words[i >> 6] &= ~(1 << UInt64(i & 63)) }
            }
        }
    }

    var uuidBytes: [UInt8] {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    // ext2fs_group_desc_csum: crc16(~0, uuid) -> group number -> descriptor (excluding checksum)
    func groupChecksum(group: UInt32, desc: [UInt8]) -> UInt16 {
        var crc = Self.crc16(0xFFFF, uuidBytes)
        crc = Self.crc16(crc, [UInt8(group & 0xff), UInt8((group >> 8) & 0xff), UInt8((group >> 16) & 0xff), UInt8(group >> 24)])
        crc = Self.crc16(crc, Array(desc[0..<30]))
        return crc
    }

    static let crc16Table: [UInt16] = (0..<256).map { i -> UInt16 in
        var c = UInt16(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (c >> 1) ^ 0xA001 : c >> 1 }
        return c
    }

    static func crc16(_ start: UInt16, _ bytes: [UInt8]) -> UInt16 {
        var crc = start
        for b in bytes { crc = (crc >> 8) ^ crc16Table[Int((crc ^ UInt16(b)) & 0xff)] }
        return crc
    }
}
