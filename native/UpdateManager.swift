import SwiftUI
import AppKit
import CryptoKit

struct YikeUpdate: Codable, Equatable {
    let version: String
    let build: Int
    let title: String
    let notes: String
    let downloadURL: URL
    let sha256: String

    enum CodingKeys: String, CodingKey {
        case version, build, title, notes, sha256
        case downloadURL = "download_url"
    }
}

struct YikeUpdateProgressView: View {
    @ObservedObject var updater: UpdateManager
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Yike 更新").font(.title2.bold())
            Text(updater.status).font(.subheadline)
            if updater.phase == .downloading, let progress = updater.downloadProgress {
                ProgressView(value: progress)
                Text("下载进度 \(Int(progress * 100))%")
                    .font(.caption).foregroundStyle(.secondary)
            } else if updater.phase == .installing || updater.phase == .starting || updater.isChecking {
                ProgressView()
            }
            HStack {
                Spacer()
                if updater.showsInstallReady {
                    Button("稍后再说") { updater.showsProgress = false }
                    Button("安装并重启 Yike") { updater.restartAndInstall() }.buttonStyle(.borderedProminent)
                } else if updater.phase == .failed {
                    Button("关闭") { updater.showsProgress = false }
                    Button("重试更新") { Task { await updater.retry() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.isChecking)
                } else if !updater.isChecking && updater.phase != .installing && updater.phase != .starting {
                    Button("关闭") { updater.showsProgress = false }
                }
            }
        }
        .padding(24)
        .frame(width: 390)
    }
}


struct YikeInstallFailureView: View {
    @ObservedObject var updater: UpdateManager

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color(nsColor: .systemRed))
            Text("安装失败")
                .font(.title2.bold())
            Text(updater.status.isEmpty ? "已保留或恢复原版本，请稍后重试更新。" : updater.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("我知道了") { updater.showsInstallError = false }
                .buttonStyle(.borderedProminent)
        }
        .padding(28)
        .frame(width: 390, height: 230)
    }
}

private final class YikeDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let progressHandler: (Double) -> Void
    var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    init(progressHandler: @escaping (Double) -> Void) { self.progressHandler = progressHandler }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressHandler(min(1, max(0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else { continuation?.resume(throwing: URLError(.badServerResponse)); return }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("Yike-download-\(UUID().uuidString).dmg")
        do { try FileManager.default.copyItem(at: location, to: target); continuation?.resume(returning: (target, response)) }
        catch { continuation?.resume(throwing: error) }
        continuation = nil
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, continuation != nil { continuation?.resume(throwing: error); continuation = nil }
    }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    enum Phase { case idle, downloading, downloadComplete, installing, starting, complete, failed }
    @Published private(set) var phase: Phase = .idle

    @Published private(set) var latest: YikeUpdate?
    @Published private(set) var isChecking = false
    @Published private(set) var status = ""
    @Published private(set) var downloadProgress: Double?
    @Published var showsUpdateAlert = false
    @Published var showsInstallError = false
    @Published var showsInstallReady = false
    @Published var showsProgress = false
    @Published var showsUpdateComplete = false
    private var stagedDMG: URL?
    private var isRestarting = false

    private let lastCheckKey = "yike.update.lastCheck"
    private let lastLaunchedBuildKey = "yike.update.lastLaunchedBuild"
    private var didHandleLaunch = false
    private let interval: TimeInterval = 24 * 60 * 60
    private var failureMarker: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.yijian.translator.kimi", isDirectory: true)
            .appendingPathComponent("yike-update-failed")
    }

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    var hasUpdate: Bool { (latest?.build ?? 0) > currentBuild }

    func checkIfNeeded() async {
        guard !didHandleLaunch else { return }
        didHandleLaunch = true
        if FileManager.default.fileExists(atPath: failureMarker.path) {
            UserDefaults.standard.removeObject(forKey: "yike.update.pendingBuild")
            presentInstallFailure("安装失败，已保留或恢复原版本。请重试更新。")
            return
        }
        let pending = UserDefaults.standard.integer(forKey: "yike.update.pendingBuild")
        let previousBuild = UserDefaults.standard.integer(forKey: lastLaunchedBuildKey)
        let checkedInOlderBuild = UserDefaults.standard.double(forKey: lastCheckKey) > 0
        if pending > 0, currentBuild >= pending {
            UserDefaults.standard.removeObject(forKey: "yike.update.pendingBuild")
            phase = .starting
        } else if previousBuild > 0, currentBuild > previousBuild {
            phase = .starting
        } else if previousBuild == 0, currentBuild >= 75, checkedInOlderBuild {
            // Build 73/74 did not record a pending build before relaunch.
            phase = .starting
        }
        UserDefaults.standard.set(currentBuild, forKey: lastLaunchedBuildKey)
        if phase == .starting {
            status = "正在启动 Yike…"
            // Let the main window draw before presenting the result.
            try? await Task.sleep(for: .milliseconds(750))
            phase = .complete
            status = "更新完毕"
            showsUpdateComplete = true
        }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= interval else { return }
        Task { _ = await check(force: false) }
    }

    enum CheckResult { case current, available, failed }

    func checkNow() async -> CheckResult? { await check(force: true) }

    func installNow() async {
        guard let update = latest, !isChecking else { return }
        isChecking = true
        showsInstallReady = false
        if let stagedDMG { try? FileManager.default.removeItem(at: stagedDMG.deletingLastPathComponent()) }
        stagedDMG = nil
        showsProgress = true
        phase = .downloading
        downloadProgress = 0
        status = "正在下载新版…"
        defer { isChecking = false }
        do {
            let request = URLRequest(url: update.downloadURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 120)
            let delegate = YikeDownloadDelegate { [weak self] value in Task { @MainActor in self?.downloadProgress = value } }
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            let (temporaryURL, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>) in
                delegate.continuation = continuation
                session.downloadTask(with: request).resume()
            }
            session.invalidateAndCancel()
            guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
            let data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
            status = "下载完成，正在校验安装包…"
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(update.sha256) == .orderedSame else { throw UpdateError.invalidChecksum }

            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("YikeUpdate-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let dmg = directory.appendingPathComponent("Yike.dmg")
            try FileManager.default.copyItem(at: temporaryURL, to: dmg)
            try? FileManager.default.removeItem(at: temporaryURL)
            stagedDMG = dmg
            downloadProgress = 1
            phase = .downloadComplete
            status = "下载完成，可以安装并重启 Yike。"
            showsInstallReady = true
        } catch {
            downloadProgress = nil
            presentInstallFailure(error is UpdateError ? "安装包校验失败，已保留当前版本。" : "更新失败：\(error.localizedDescription) 已保留当前版本，请稍后重试。")
        }
    }

    func retry() async {
        if latest == nil || !hasUpdate {
            guard await check(force: true) == .available else {
                presentInstallFailure("更新仍未完成，暂时无法获取安装包。请检查网络后重试。")
                return
            }
        }
        await installNow()
    }

    func restartAndInstall() {
        guard let dmg = stagedDMG, !isRestarting else { return }
        isRestarting = true
        do {
            let directory = dmg.deletingLastPathComponent()
            let helper = directory.appendingPathComponent("install.sh")
            guard let bundledHelper = Bundle.main.url(forResource: "UpdateInstaller", withExtension: "sh") else { throw UpdateError.missingInstaller }
            if FileManager.default.fileExists(atPath: helper.path) { try FileManager.default.removeItem(at: helper) }
            try FileManager.default.copyItem(at: bundledHelper, to: helper)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), dmg.path, Bundle.main.bundleURL.path, Bundle.main.bundleIdentifier ?? "com.yijian.translator.kimi", failureMarker.path]
            process.terminationHandler = { [weak self] process in
                guard process.terminationStatus != 0 else { return }
                Task { @MainActor in
                    guard let self, self.isRestarting else { return }
                    self.isRestarting = false
                    self.presentInstallFailure("安装未完成，已保留或恢复原版本。请重试更新。")
                }
            }
            try process.run()
            if let latest { UserDefaults.standard.set(latest.build, forKey: "yike.update.pendingBuild") }
            UserDefaults.standard.synchronize()
            phase = .installing; showsInstallReady = false; status = "安装中，Yike 即将重新启动…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showsProgress = false
                if NSApp.modalWindow != nil { NSApp.abortModal() }
                for window in NSApp.windows {
                    if let sheet = window.attachedSheet { window.endSheet(sheet) }
                }
                NSApp.terminate(nil)
            }
        } catch {
            isRestarting = false; showsInstallReady = false
            presentInstallFailure("无法启动安装，请重试更新：\(error.localizedDescription)")
        }
    }

    private func presentInstallFailure(_ message: String) {
        phase = .failed
        status = message
        showsProgress = false
        showsInstallError = true
    }

    private func check(force: Bool) async -> CheckResult? {
        guard !isChecking else { return nil }
        isChecking = true
        status = force ? "正在检查更新…" : ""
        defer { isChecking = false }

        guard let base = Bundle.main.object(forInfoDictionaryKey: "YikeTrialAPIBaseURL") as? String,
              let url = URL(string: base)?.appendingPathComponent("v1/update/macos") else {
            if force { status = "更新服务地址无效。" }
            return .failed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let update = try JSONDecoder().decode(YikeUpdate.self, from: data)
            latest = update
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            if update.build > currentBuild {
                status = "发现新版本 \(update.version)（Build \(update.build)）"
                if !force { showsUpdateAlert = true }
                return .available
            } else {
                status = "当前已是最新版。"
                return .current
            }
        } catch {
            if force { status = "暂时无法检查更新，请确认网络后重试。" }
            return .failed
        }
    }

    private enum UpdateError: Error { case invalidChecksum, missingInstaller }

    private static let installerScript = #"""
#!/bin/zsh
set -u
old_pid="$1"
dmg="$2"
current_app="$3"
expected_id="$4"
failure_marker="$5"
fail() {
    /bin/mkdir -p "$(dirname "$failure_marker")"
    /usr/bin/touch "$failure_marker"
    [[ -d "$current_app" ]] && /usr/bin/open "$current_app" >/dev/null 2>&1 || true
    exit 1
}
for _ in {1..300}; do
    kill -0 "$old_pid" 2>/dev/null || break
    sleep 0.1
done
if kill -0 "$old_pid" 2>/dev/null; then fail; fi
mount_dir="$(mktemp -d /tmp/yike-update-mount.XXXXXX)" || fail
backup_root="$(mktemp -d /tmp/yike-update-backup.XXXXXX)" || fail
backup_app="$backup_root/Yike.app"
cleanup() {
    /usr/bin/hdiutil detach "$mount_dir" -quiet 2>/dev/null || true
    /bin/rm -rf "$mount_dir" "$backup_root" "$(dirname "$dmg")"
}
trap cleanup EXIT
/usr/bin/hdiutil verify "$dmg" >/dev/null || fail
/usr/bin/hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mount_dir" >/dev/null || fail
new_app="$mount_dir/Yike.app"
actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$new_app/Contents/Info.plist" 2>/dev/null)"
[[ "$actual_id" == "$expected_id" ]] || fail
/usr/bin/codesign --verify --deep --strict "$new_app" || fail
/usr/bin/ditto "$current_app" "$backup_app" || fail
/bin/rm -rf "$current_app" || fail
if ! /usr/bin/ditto "$new_app" "$current_app" || ! /usr/bin/codesign --verify --deep --strict "$current_app"; then
    /bin/rm -rf "$current_app"
    /usr/bin/ditto "$backup_app" "$current_app"
    fail
fi
if ! /usr/bin/open "$current_app"; then fail; fi
/bin/rm -f "$failure_marker"
"""#
}
