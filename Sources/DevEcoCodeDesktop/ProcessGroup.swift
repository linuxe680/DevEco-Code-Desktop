import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Launches a child process in its own process group so the entire tree
/// (e.g. `deveco` launcher → Node.js server) can be terminated together.
///
/// `Process.terminate()` only signals the direct child. The deveco CLI is a
/// `#!/usr/bin/env node` script that may exec/spawn Node; killing only the
/// launcher leaves an orphan listening on the port we just told the user was
/// stopped. `posix_spawn` with `POSIX_SPAWN_SETPGROUP` gives us a group leader
/// whose PID equals the group ID, so `kill(-pgid, …)` reaches every descendant.
enum ProcessGroupLauncher {
    struct Configuration {
        let executable: URL
        let arguments: [String]
        let environment: [String: String]
        let workingDirectory: URL
        let stdout: FileHandle
        let stderr: FileHandle
    }

    struct Launched {
        let pid: pid_t

        /// Sends SIGTERM to the whole group. If the group is still alive after
        /// `gracePeriod`, escalates to SIGKILL so no orphan can survive.
        func terminate(gracePeriod: TimeInterval = 1.5) {
            let group = pid
            guard group > 0 else { return }
            _ = kill(-group, SIGTERM)
            guard gracePeriod > 0 else { return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + gracePeriod
            ) {
                // ESRCH means the group is already gone — nothing to do.
                if kill(-group, 0) == 0 {
                    _ = kill(-group, SIGKILL)
                }
            }
        }

        /// Blocks the calling thread until every process in the group is gone.
        /// Returns false when the group is still alive after `timeout`.
        @discardableResult
        func waitUntilExit(timeout: TimeInterval = 5) -> Bool {
            let group = pid
            guard group > 0 else { return true }
            let deadline = Date().addingTimeInterval(timeout)
            var leaderReaped = false
            while Date() < deadline {
                if !leaderReaped {
                    var status: Int32 = 0
                    let result = waitpid(group, &status, WNOHANG)
                    // The leader is this process's direct child, so it must be
                    // reaped here: a zombie would keep `kill(-pgid, 0)`
                    // succeeding forever.
                    leaderReaped = result == group || (result == -1 && errno == ECHILD)
                }
                if leaderReaped, kill(-group, 0) != 0, errno == ESRCH { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return leaderReaped && kill(-group, 0) != 0 && errno == ESRCH
        }
    }

    static func launch(_ config: Configuration) throws -> Launched {
        var attributes: posix_spawnattr_t? = nil
        let initResult = posix_spawnattr_init(&attributes)
        guard initResult == 0 else { throw spawnError(initResult, operation: "posix_spawnattr_init") }
        defer { posix_spawnattr_destroy(&attributes) }

        var flags: Int16 = 0
        let flagsResult = posix_spawnattr_getflags(&attributes, &flags)
        guard flagsResult == 0 else { throw spawnError(flagsResult, operation: "posix_spawnattr_getflags") }
        flags |= Int16(POSIX_SPAWN_SETPGROUP)
        let setFlagsResult = posix_spawnattr_setflags(&attributes, flags)
        guard setFlagsResult == 0 else { throw spawnError(setFlagsResult, operation: "posix_spawnattr_setflags") }
        let setGroupResult = posix_spawnattr_setpgroup(&attributes, 0)
        guard setGroupResult == 0 else { throw spawnError(setGroupResult, operation: "posix_spawnattr_setpgroup") }

        var fileActions: posix_spawn_file_actions_t? = nil
        let actionsInit = posix_spawn_file_actions_init(&fileActions)
        guard actionsInit == 0 else { throw spawnError(actionsInit, operation: "posix_spawn_file_actions_init") }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        // posix_spawn uses execve semantics (no PATH search); caller passes an
        // absolute executable path. Change the child's cwd via file actions so
        // the parent app's cwd is never touched.
        if #available(macOS 26.0, *) {
            let result = config.workingDirectory.path.withCString {
                posix_spawn_file_actions_addchdir(&fileActions, $0)
            }
            guard result == 0 else { throw spawnError(result, operation: "addchdir") }
        } else {
            let result = config.workingDirectory.path.withCString {
                posix_spawn_file_actions_addchdir_np(&fileActions, $0)
            }
            guard result == 0 else { throw spawnError(result, operation: "addchdir_np") }
        }

        // Wire the child's stdout/stderr to the caller's handles. Without
        // this, the deveco server's output goes nowhere: the log tail stays
        // empty and crash diagnostics (e.g. "node: No such file") are lost.
        let stdoutResult = posix_spawn_file_actions_adddup2(
            &fileActions, config.stdout.fileDescriptor, Int32(STDOUT_FILENO)
        )
        guard stdoutResult == 0 else { throw spawnError(stdoutResult, operation: "adddup2(stdout)") }
        let stderrResult = posix_spawn_file_actions_adddup2(
            &fileActions, config.stderr.fileDescriptor, Int32(STDERR_FILENO)
        )
        guard stderrResult == 0 else { throw spawnError(stderrResult, operation: "adddup2(stderr)") }

        var argv: [UnsafeMutablePointer<CChar>?] = []
        var envp: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        argv.append(strdup(config.executable.path))
        for argument in config.arguments {
            argv.append(strdup(argument))
        }
        argv.append(nil)
        for (key, value) in config.environment {
            envp.append(strdup("\(key)=\(value)"))
        }
        envp.append(nil)

        var pid: pid_t = 0
        let spawnResult = argv.withUnsafeMutableBufferPointer { argvBuffer in
            envp.withUnsafeMutableBufferPointer { envpBuffer in
                posix_spawn(
                    &pid,
                    config.executable.path,
                    &fileActions,
                    &attributes,
                    argvBuffer.baseAddress,
                    envpBuffer.baseAddress
                )
            }
        }
        guard spawnResult == 0 else { throw spawnError(spawnResult, operation: "posix_spawn") }

        return Launched(pid: pid)
    }

    private static func spawnError(_ code: Int32, operation: String) -> Error {
        NSError(
            domain: "ProcessGroupLauncher",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
        )
    }
}
