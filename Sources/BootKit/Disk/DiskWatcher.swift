import Foundation
import DiskArbitration

/// Notifies when disks appear or disappear (USB hot-plug), debounced.
public final class DiskWatcher: @unchecked Sendable {
    private var session: DASession?
    private let onChange: () -> Void
    private var pending: DispatchWorkItem?

    public init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    public func start() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().schedule()
        }, ctx)
        DARegisterDiskDisappearedCallback(s, nil, { _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().schedule()
        }, ctx)
        DARegisterDiskDescriptionChangedCallback(s, nil, nil, { _, _, ctx in
            guard let ctx else { return }
            Unmanaged<DiskWatcher>.fromOpaque(ctx).takeUnretainedValue().schedule()
        }, ctx)
        DASessionSetDispatchQueue(s, DispatchQueue.main)
    }

    public func stop() {
        if let s = session { DASessionSetDispatchQueue(s, nil) }
        session = nil
    }

    private func schedule() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    deinit { stop() }
}
