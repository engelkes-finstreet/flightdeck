import Foundation
import CoreServices

/// Fires `onChange` when anything inside the watched directories is created,
/// modified, renamed or removed.
///
/// This is Flightdeck's primary refresh trigger. It is deliberately *not*
/// tied to app activation, window focus, or a slow poll: Claude Code writes
/// the session file from its own process the moment its state changes, so an
/// FSEvents subscription sees the transition immediately whether or not the
/// terminal running that agent is frontmost.
final class DirectoryWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "codes.flightdeck.fsevents")

    init(paths: [String], latency: CFTimeInterval = 0.05, onChange: @escaping () -> Void) {
        self.paths = paths
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }

        // FSEvents hands us a raw pointer; retain an unmanaged box for the
        // lifetime of the stream and release it in stop().
        let box = Unmanaged.passRetained(CallbackBox(onChange)).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: box,
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue().fire()
            },
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            Unmanaged<CallbackBox>.fromOpaque(box).release()
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }

    private final class CallbackBox {
        private let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        func fire() { action() }
    }
}
