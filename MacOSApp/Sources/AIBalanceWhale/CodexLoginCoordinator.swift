import Cocoa

/// Starts the official Codex browser login without a shell or credential
/// hand-off. Codex owns the OAuth callback, token exchange, and auth storage.
/// This process is never attached to the app-server process we manage.
final class CodexLoginCoordinator {
    var onResult: ((ProviderError?) -> Void)?
    private var process: Process?
    private var output: Pipe?
    private var timeoutWorkItem: DispatchWorkItem?
    private var loginGeneration = 0
    private var timedOutGeneration: Int?

    func start() {
        guard process == nil else { onResult?(.unsupported("Codex 登录已经在进行中")); return }
        let path = AppPreferences.shared.codexPath
        guard let executable = CodexLocator.executable(configuredPath: path) else {
            onResult?(.cliMissing); return
        }
        loginGeneration += 1
        let generation = loginGeneration
        timedOutGeneration = nil
        let child = Process()
        child.executableURL = executable
        child.arguments = ["login"]
        child.environment = CodexLocator.childEnvironment(for: executable, configuredHome: AppPreferences.shared.codexHome)
        let pipe = Pipe()
        child.standardOutput = pipe
        child.standardError = pipe
        // Drain progress output so the official CLI cannot block on a full
        // pipe during a browser login. Output is never forwarded to WebView
        // or diagnostics because it may contain sensitive details.
        pipe.fileHandleForReading.readabilityHandler = { handle in
            _ = try? handle.read(upToCount: 4096)
        }
        child.terminationHandler = { [weak self] child in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.loginGeneration == generation, self.process === child else { return }
                let timedOut = self.timedOutGeneration == generation
                self.timedOutGeneration = nil
                self.timeoutWorkItem?.cancel()
                self.timeoutWorkItem = nil
                pipe.fileHandleForReading.readabilityHandler = nil
                self.process = nil
                self.output = nil
                if timedOut {
                    self.onResult?(.timeout(stage: "Codex 浏览器登录", seconds: 600))
                } else {
                    self.onResult?(child.terminationStatus == 0 ? nil : .processExited(stage: "browser login"))
                }
            }
        }
        do {
            try child.run()
            process = child
            output = pipe
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.loginGeneration == generation, self.process === child else { return }
                self.timedOutGeneration = generation
                child.terminate()
            }
            timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 600, execute: timeout)
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            onResult?(.launch("无法启动 Codex 登录：\(error.localizedDescription)"))
        }
    }

    func cancel() {
        loginGeneration += 1
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        timedOutGeneration = nil
        process?.terminate()
        process = nil
        output = nil
    }
}
