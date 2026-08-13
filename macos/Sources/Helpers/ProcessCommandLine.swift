import Darwin
import Foundation

/// Reads the command line of a running process.
///
/// Session restore uses this to work out what a surface was actually running
/// when we saved it, so that reopening the surface can put the user back where
/// they were instead of dropping them at a bare shell.
///
/// This only works for processes owned by the same user, which is all we ever
/// need: every process we ask about is a descendant of one of our ptys.
enum ProcessCommandLine {
    /// The argument vector of the given process, or nil if it can't be read.
    ///
    /// Reading fails routinely and harmlessly: the process may have exited
    /// between us seeing its pid and asking about it. Callers should treat nil
    /// as "we don't know", never as an error.
    static func argv(pid: pid_t) -> [String]? {
        guard pid > 0 else { return nil }
        guard let raw = procArgs2(pid: pid) else { return nil }
        return parse(procArgs2: raw)
    }

    /// The absolute path of the executable backing the given process.
    ///
    /// Note this is the *resolved* executable, which is not necessarily
    /// anything the user typed. See `SessionRestoreCommand` for why that
    /// distinction matters.
    static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Private

    /// The largest blob the kernel will ever hand back. Fixed for the life of
    /// the system, and we ask often enough that it's worth not re-asking.
    private static let argMax: Int? = {
        var value: CInt = 0
        var size = MemoryLayout<CInt>.size
        var mib: [CInt] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }()

    /// Fetch the raw KERN_PROCARGS2 blob for a process.
    private static func procArgs2(pid: pid_t) -> [UInt8]? {
        // sysctl won't tell us the real size for KERN_PROCARGS2 up front, so
        // we have to allocate for the worst case.
        guard let argMax = Self.argMax else { return nil }

        var buffer = [UInt8](repeating: 0, count: argMax)
        var size = buffer.count
        var mib: [CInt] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = buffer.withUnsafeMutableBytes { ptr in
            sysctl(&mib, 3, ptr.baseAddress, &size, nil, 0)
        }
        guard result == 0, size > MemoryLayout<CInt>.size else { return nil }

        buffer.removeLast(buffer.count - size)
        return buffer
    }

    /// Parse a KERN_PROCARGS2 blob into an argument vector.
    ///
    /// The layout is: a 32-bit argc, the executable path, some number of NUL
    /// bytes of padding, then argc NUL-terminated arguments, then the
    /// environment (which we don't want and stop before).
    ///
    /// Exposed for testing; there is no way to synthesize a real process with
    /// a chosen argv from a unit test.
    static func parse(procArgs2 buffer: [UInt8]) -> [String]? {
        let argcSize = MemoryLayout<CInt>.size
        guard buffer.count > argcSize else { return nil }

        let argc = buffer.withUnsafeBytes { ptr in
            ptr.loadUnaligned(as: CInt.self)
        }
        guard argc > 0 else { return nil }

        // Skip the executable path.
        var index = argcSize
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        // Skip the padding NULs between the path and argv[0].
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        guard index < buffer.count else { return nil }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        var start = index
        while index < buffer.count, args.count < Int(argc) {
            guard buffer[index] == 0 else {
                index += 1
                continue
            }

            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
            start = index
        }

        // A truncated blob gives us fewer arguments than argc promised. We'd
        // rather restore nothing than restore a command with its tail cut off.
        guard args.count == Int(argc) else { return nil }
        return args
    }
}
