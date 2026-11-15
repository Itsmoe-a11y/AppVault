import Foundation
import UIKit
import Darwin

public final class PosixHelper {
    public static let shared = PosixHelper()

    private init() {}

    // MARK: - Execute Command via posix_spawn
    @discardableResult
    public func execute(
        _ executable: String,
        arguments: [String] = [],
        environment: [String: String]? = nil
    ) -> (exitCode: Int32, output: String) {
        var pipedes: [Int32] = [0, 0]
        guard pipe(&pipedes) == 0 else {
            return (-1, "Failed to create posix pipe")
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_addclose(&fileActions, pipedes[0])
        posix_spawn_file_actions_adddup2(&fileActions, pipedes[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, pipedes[1], STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, pipedes[1])

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)

        var argv: [UnsafeMutablePointer<CChar>?] = []
        argv.append(strdup(executable))
        for arg in arguments {
            argv.append(strdup(arg))
        }
        argv.append(nil)

        var envp: [UnsafeMutablePointer<CChar>?] = []
        var mergedEnv: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/var/jb/usr/bin:/var/jb/bin",
            "HOME": "/var/mobile",
            "TMPDIR": NSTemporaryDirectory()
        ]
        if let customEnv = environment {
            for (k, v) in customEnv {
                mergedEnv[k] = v
            }
        }
        for (k, v) in mergedEnv {
            envp.append(strdup("\(k)=\(v)"))
        }
        envp.append(nil)

        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &fileActions, &attr, argv, envp)

        for ptr in argv where ptr != nil { free(ptr) }
        for ptr in envp where ptr != nil { free(ptr) }
        posix_spawn_file_actions_destroy(&fileActions)
        posix_spawnattr_destroy(&attr)

        close(pipedes[1])

        guard status == 0 else {
            close(pipedes[0])
            return (status, "posix_spawn failed with error: \(status)")
        }

        let readHandle = FileHandle(fileDescriptor: pipedes[0], closeOnDealloc: true)
        let outputData = readHandle.readDataToEndOfFile()
        let outputString = String(data: outputData, encoding: .utf8) ?? ""

        var exitStatus: Int32 = 0
        waitpid(pid, &exitStatus, 0)

        let finalCode = (exitStatus >> 8) & 0xff
        return (finalCode, outputString)
    }

    // MARK: - Terminate App Processes by Executable Name
    public func terminateApp(named executableName: String) {
        guard !executableName.isEmpty else { return }
        _ = execute("/usr/bin/killall", arguments: ["-9", executableName])
        _ = execute("/bin/killall", arguments: ["-9", executableName])
        _ = execute("/var/jb/usr/bin/killall", arguments: ["-9", executableName])
    }

    // MARK: - Fix Permissions Recursively (mobile:mobile 501:501)
    public func fixPermissions(at path: String, uid: uid_t = 501, gid: gid_t = 501) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else { return }

        // 1. Native POSIX change on root path
        chown(path, uid, gid)
        chmod(path, 0o755)

        // 2. Iterate subpaths
        if let enumerator = fileManager.enumerator(atPath: path) {
            while let subpath = enumerator.nextObject() as? String {
                let fullPath = (path as NSString).appendingPathComponent(subpath)
                chown(fullPath, uid, gid)
                
                var isDir: ObjCBool = false
                if fileManager.fileExists(atPath: fullPath, isDirectory: &isDir) {
                    if isDir.boolValue {
                        chmod(fullPath, 0o755)
                    } else {
                        chmod(fullPath, 0o644)
                    }
                }
            }
        }

        // 3. Fallback shell chown if available
        if fileManager.fileExists(atPath: "/usr/sbin/chown") {
            _ = execute("/usr/sbin/chown", arguments: ["-R", "\(uid):\(gid)", path])
        } else if fileManager.fileExists(atPath: "/bin/chown") {
            _ = execute("/bin/chown", arguments: ["-R", "\(uid):\(gid)", path])
        }
    }

    // MARK: - Compression via ditto (Native Apple Zip / Preserve Resource Forks)
    public func dittoArchive(sourceDir: String, destinationZip: String) -> Bool {
        let dittoPaths = ["/usr/bin/ditto", "/bin/ditto", "/var/jb/usr/bin/ditto"]
        for ditto in dittoPaths {
            if FileManager.default.isExecutableFile(atPath: ditto) {
                let result = execute(ditto, arguments: [
                    "-c", "-k",
                    "--sequesterRsrc",
                    "--keepParent",
                    sourceDir,
                    destinationZip
                ])
                if result.exitCode == 0 && FileManager.default.fileExists(atPath: destinationZip) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Extraction via ditto
    public func dittoExtract(zipPath: String, destinationDir: String) -> Bool {
        let dittoPaths = ["/usr/bin/ditto", "/bin/ditto", "/var/jb/usr/bin/ditto"]
        for ditto in dittoPaths {
            if FileManager.default.isExecutableFile(atPath: ditto) {
                let result = execute(ditto, arguments: [
                    "-x", "-k",
                    zipPath,
                    destinationDir
                ])
                if result.exitCode == 0 {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - TrollStore URL Scheme Trigger
    @MainActor
    public func installViaTrollStore(at url: URL) {
        guard let encoded = url.path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let trollStoreURL = URL(string: "apple-magnifier://install?url=\(encoded)") else {
            return
        }
        if UIApplication.shared.canOpenURL(trollStoreURL) {
            UIApplication.shared.open(trollStoreURL, options: [:], completionHandler: nil)
        }
    }
}
