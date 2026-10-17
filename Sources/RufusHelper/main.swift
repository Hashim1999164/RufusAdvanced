import Foundation
import BootKit

// rufusadv-helper — the worker that touches disks.
//
// The app launches it with administrator privileges (one password prompt per operation):
//     rufusadv-helper run --job <base64 JSON> --events <file> --cancel <file>
// It can also be used directly from a terminal (see `rufusadv-helper help`).

setvbuf(stdout, nil, _IOLBF, 0)
signal(SIGPIPE, SIG_IGN)

func usage() -> Never {
    print("""
    rufusadv-helper \(BootKit.version) — create bootable USB drives from the command line

    USAGE
      rufusadv-helper list [--all] [--images]          List candidate target drives
      rufusadv-helper inspect <image>                  Analyse an ISO / IMG / installer
      rufusadv-helper write --image <file> --device <diskN> [options]
      rufusadv-helper format --device <diskN> [--boot nonbootable|freedos|syslinux6|syslinux4|grub2|uefintfs] [options]
      rufusadv-helper save --device <diskN> --output <file.img|.vhd|.dmg>
      rufusadv-helper badblocks --device <diskN> [--passes 1|2|slc|mlc|tlc]
      rufusadv-helper run --job <base64> --events <file> [--cancel <file>]   (used by the app)

    WRITE / FORMAT OPTIONS
      --mode iso|dd|mac            Write mode (default: recommended for the image)
      --scheme gpt|mbr             Partition scheme
      --target uefi|bios|both      Target system
      --fs FAT32|exFAT|NTFS|FAT|UDF|ext2|ext3|ext4|HFS+   File system
      --cluster <bytes>            Cluster size
      --label <name>               Volume label
      --persistence <MB>           Linux persistence partition size
      --slow-format                Zero the partition before formatting
      --verify                     Read back and verify (DD mode)
      --bad-blocks <passes>        Check for bad blocks first
      --win-bypass / --win-local-account <name> / --win-no-online / --win-no-telemetry / --win-no-bitlocker
      --uefi-validation            Install uefi-md5sum runtime media validation
      --no-eject                   Keep the drive attached when done
      --allow-images               Allow attached disk images as targets (testing)
      --yes                        Don't ask for confirmation (DANGEROUS)
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

func value(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }

func printJSON<T: Encodable>(_ v: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let d = try? enc.encode(v) { print(String(decoding: d, as: UTF8.self)) }
}

/// Event sink writing JSON lines to a file the app tails. When running as root the file must
/// already exist, be a regular file and be owned by the invoking user (no symlink games).
final class EventFile {
    let fd: Int32
    let lock = NSLock()
    init?(path: String, ownerUID: UInt32) {
        let f = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC)
        guard f >= 0 else { return nil }
        var st = stat()
        guard fstat(f, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == ownerUID || getuid() != 0 else {
            close(f)
            return nil
        }
        fd = f
    }
    func write(_ e: JobEvent) {
        let line = e.jsonLine
        lock.lock(); defer { lock.unlock() }
        _ = line.withCString { Darwin.write(fd, $0, strlen($0)) }
    }
}

/// Terminal reporter for direct CLI use.
func terminalReporter() -> JobReporter {
    var lastLine = ""
    return JobReporter { event in
        switch event {
        case .started:
            break
        case .log(let entry):
            if entry.level != .debug {
                FileHandle.standardError.write(Data(("\r\u{1B}[K" + entry.formatted + "\n").utf8))
            }
        case .progress(let p):
            var line = p.phase
            if let f = p.overall ?? p.fraction { line = String(format: "[%3.0f%%] ", f * 100) + line }
            if let d = p.detail { line += " — " + d }
            if let r = p.bytesPerSecond { line += " (\(Units.rate(r)))" }
            if line != lastLine {
                lastLine = line
                FileHandle.standardError.write(Data(("\r\u{1B}[K" + String(line.prefix(120))).utf8))
            }
        case .finished(let ok, let err, let notices):
            FileHandle.standardError.write(Data("\n".utf8))
            for n in notices { print("• \(n)") }
            print(ok ? "✅ Done." : "❌ \(err ?? "Failed")")
        }
    }
}

func confirm(_ disk: DiskInfo) {
    if flag("--yes") { return }
    print("⚠️  ALL DATA ON \(disk.displayName) (\(disk.subtitle)) WILL BE DESTROYED.\nType the disk identifier (\(disk.identifier)) to continue: ", terminator: "")
    guard readLine() == disk.identifier else { print("Aborted."); exit(1) }
}

func targetDisk() -> DiskInfo {
    guard let id = value("--device")?.replacingOccurrences(of: "/dev/", with: "").replacingOccurrences(of: "/dev/r", with: ""),
          let d = DiskEnumerator.info(id) else {
        print("Unknown or missing --device"); exit(1)
    }
    return d
}

func applyCommonOptions(_ spec: inout JobSpec, image: ImageReport?) {
    if let s = value("--scheme") { spec.partitionScheme = s.lowercased() == "mbr" ? .mbr : .gpt }
    if let t = value("--target")?.lowercased() { spec.targetSystem = t == "bios" ? .bios : (t == "both" ? .biosOrUefi : .uefi) }
    if let f = value("--fs") {
        spec.fileSystem = FileSystemType.allCases.first { $0.rawValue.lowercased() == f.lowercased() || $0.shortName.lowercased() == f.lowercased() } ?? spec.fileSystem
    }
    if let c = value("--cluster").flatMap(UInt32.init) { spec.clusterSize = c }
    if let l = value("--label") { spec.label = l }
    if let p = value("--persistence").flatMap(UInt64.init) { spec.persistenceSize = p * Units.MB }
    spec.quickFormat = !flag("--slow-format")
    spec.verifyWrite = flag("--verify")
    spec.uefiMediaValidation = flag("--uefi-validation")
    spec.ejectWhenDone = !flag("--no-eject")
    spec.allowVirtualDisks = flag("--allow-images")
    if let b = value("--bad-blocks") {
        let set: BadBlocksOptions.PatternSet = ["2": .twoPasses, "slc": .slc, "mlc": .mlc, "tlc": .tlc][b.lowercased()] ?? .onePass
        spec.badBlocks = BadBlocksOptions(patternSet: set)
    }
    if image?.family == .windows {
        var c = WindowsCustomization()
        c.bypassRequirements = flag("--win-bypass")
        c.noOnlineAccount = flag("--win-no-online")
        c.disableDataCollection = flag("--win-no-telemetry")
        c.disableBitLocker = flag("--win-no-bitlocker")
        c.localAccountName = value("--win-local-account")
        spec.windows = c
    }
}

switch command {
case "version", "--version":
    print("rufusadv-helper \(BootKit.version)")

case "list":
    let disks = DiskEnumerator.list(.init(includeUSBHardDrives: flag("--all"), includeDiskImages: flag("--images"), includeOtherExternal: true))
    if flag("--json") { printJSON(disks) } else if disks.isEmpty { print("No removable drives found.") }
    else { for d in disks { print("\(d.identifier)\t\(d.displayName)\t\(d.subtitle)") } }

case "inspect":
    guard let path = args.first else { usage() }
    do { printJSON(try ImageInspector.inspect(path: path)) } catch { print("Error: \(error.userMessage)"); exit(1) }

case "write", "format", "save", "badblocks":
    let disk = targetDisk()
    var spec = JobSpec(disk: disk.identifier, diskSize: disk.size, diskMediaName: disk.mediaName)
    var image: ImageReport?
    switch command {
    case "write":
        guard let path = value("--image") else { usage() }
        do { image = try ImageInspector.inspect(path: path) } catch { print("Error: \(error.userMessage)"); exit(1) }
        spec.imagePath = path
        spec.image = image
        spec.bootSelection = image!.family == .macOS ? .macInstaller : .image
        let plan = MediaPlanner.recommend(image: image!, disk: disk)
        spec.writeMode = plan.writeMode
        spec.partitionScheme = plan.scheme
        spec.targetSystem = plan.target
        spec.fileSystem = plan.fileSystem
        spec.label = plan.label
        switch value("--mode")?.lowercased() {
        case "dd": spec.writeMode = .dd
        case "iso": spec.writeMode = .iso
        case "mac": spec.writeMode = .createInstallMedia
        default: break
        }
    case "format":
        let boots: [String: BootSelection] = ["nonbootable": .nonBootable, "freedos": .freeDOS, "syslinux6": .syslinux6,
                                              "syslinux4": .syslinux4, "grub2": .grub2, "uefintfs": .uefiNTFS]
        spec.bootSelection = boots[(value("--boot") ?? "nonbootable").lowercased()] ?? .nonBootable
        spec.fileSystem = .fat32
        spec.targetSystem = .biosOrUefi
        spec.partitionScheme = .mbr
    case "save":
        guard let out = value("--output") else { usage() }
        spec.operation = .saveImage
        spec.saveImagePath = (out as NSString).expandingTildeInPath
        spec.saveFormat = out.hasSuffix(".vhd") ? .vhd : (out.hasSuffix(".dmg") ? .dmg : .img)
    default:
        spec.operation = .badBlocksOnly
        spec.badBlocks = BadBlocksOptions(patternSet: ["2": .twoPasses, "slc": .slc, "mlc": .mlc, "tlc": .tlc][(value("--passes") ?? "1").lowercased()] ?? .onePass)
    }
    applyCommonOptions(&spec, image: image)
    if spec.operation != .saveImage { confirm(disk) }
    let ok = JobRunner.run(spec, reporter: terminalReporter(), cancel: CancellationToken())
    exit(ok ? 0 : 1)

case "run":
    guard let job = value("--job"), let eventsPath = value("--events") else { usage() }
    let spec: JobSpec
    do { spec = try JobSpec.decode(job) } catch { print("Invalid job: \(error)"); exit(2) }
    guard let events = EventFile(path: eventsPath, ownerUID: spec.ownerUID) else {
        print("Cannot open the events file safely."); exit(2)
    }
    let cancel = CancellationToken(cancelFile: value("--cancel"))
    Log.shared.verbose = true
    let reporter = JobReporter { events.write($0) }
    events.write(.started(pid: getpid()))
    let ok = JobRunner.run(spec, reporter: reporter, cancel: cancel)
    exit(ok ? 0 : 1)

default:
    usage()
}
