import UIKit
import WebKit
import Capacitor

/// CAPBridgeViewController subclass that records WKWebView startup and
/// exposes an on-device "DIAG" viewer/share sheet, so logs are retrievable
/// even when the web app never renders.
class DiagnosticBridgeViewController: CAPBridgeViewController {

    private var proxyDelegate: DiagnosticNavigationDelegate?
    private var startupTimer: Timer?
    private var diagButton: UIButton?
    private var progressObservation: NSKeyValueObservation?

    override func capacitorDidLoad() {
        super.capacitorDidLoad()

       if let config = bridge?.config {
    NativeDiagnostics.shared.log("capacitor_config", [
        "server_url": config.serverURL.absoluteString,
        "app_start_server_url": config.appStartServerURL.absoluteString,
        "local_url": config.localURL.absoluteString,
        "app_start_path": config.appStartPath,
        "url_kind": NativeDiagnostics.classify(config.serverURL),
    ])
} else {
    NativeDiagnostics.shared.log("capacitor_config_missing")
}
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        installProxyDelegate()
        installDiagButton()
        startStartupWatchdog()

        if let webView {
            NativeDiagnostics.shared.log("initial_url", [
                "initial_url": webView.url?.absoluteString ?? "nil",
                "url_kind": NativeDiagnostics.classify(webView.url),
            ])
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { wv, _ in
                if wv.estimatedProgress >= 1.0 {
                    NativeDiagnostics.shared.log("progress_complete", [
                        "current_url": wv.url?.absoluteString ?? "nil",
                    ])
                }
            }
        } else {
            NativeDiagnostics.shared.log("webview_missing", ["reason": "bridge webView was nil in viewDidLoad"])
        }
    }

    private func installProxyDelegate() {
        guard let webView else { return }
        let proxy = DiagnosticNavigationDelegate(target: webView.navigationDelegate)
        proxyDelegate = proxy
        webView.navigationDelegate = proxy
        NativeDiagnostics.shared.log("diagnostics_installed", [
            "had_existing_delegate": proxy.target != nil,
        ])
    }

    private func startStartupWatchdog() {
        startupTimer?.invalidate()
        startupTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            guard let self else { return }
            let finished = NativeDiagnostics.shared.didFinishNavigation
            NativeDiagnostics.shared.log("startup_watchdog", [
                "did_finish_navigation": finished,
                "current_url": self.webView?.url?.absoluteString ?? "nil",
                "url_kind": NativeDiagnostics.classify(self.webView?.url),
                "last_error": NativeDiagnostics.shared.lastError ?? "none",
            ])
            if !finished { self.markDiagButtonFailed() }
        }
    }

    // MARK: - On-device viewer

    private func installDiagButton() {
        let button = UIButton(type: .system)
        button.setTitle("DIAG", for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = UIColor.black.withAlphaComponent(0.45)
        button.layer.cornerRadius = 12
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(showDiagnostics), for: .touchUpInside)
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 54),
            button.heightAnchor.constraint(equalToConstant: 24),
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
        ])
        diagButton = button
    }

    private func markDiagButtonFailed() {
        diagButton?.backgroundColor = UIColor.systemRed
    }

    @objc private func showDiagnostics() {
        let vc = UIViewController()
        vc.view.backgroundColor = .systemBackground

        let textView = UITextView()
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.text = NativeDiagnostics.shared.readAll()
        textView.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(textView)

        let share = UIButton(type: .system)
        share.setTitle("Share log file", for: .normal)
        share.translatesAutoresizingMaskIntoConstraints = false
        share.addTarget(self, action: #selector(shareDiagnostics), for: .touchUpInside)
        vc.view.addSubview(share)

        let close = UIButton(type: .system)
        close.setTitle("Close", for: .normal)
        close.translatesAutoresizingMaskIntoConstraints = false
        close.addTarget(self, action: #selector(closeDiagnostics), for: .touchUpInside)
        vc.view.addSubview(close)

        NSLayoutConstraint.activate([
            close.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            close.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor, constant: 16),
            share.centerYAnchor.constraint(equalTo: close.centerYAnchor),
            share.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: close.bottomAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])

        vc.modalPresentationStyle = .fullScreen
        present(vc, animated: true)
    }

    @objc private func closeDiagnostics() {
        presentedViewController?.dismiss(animated: true)
    }

    @objc private func shareDiagnostics(_ sender: UIButton) {
        let url = NativeDiagnostics.shared.fileURL
        let items: [Any] = FileManager.default.fileExists(atPath: url.path)
            ? [url]
            : [NativeDiagnostics.shared.readAll()]
        let share = UIActivityViewController(activityItems: items, applicationActivities: nil)
        share.popoverPresentationController?.sourceView = sender
        share.popoverPresentationController?.sourceRect = sender.bounds
        (presentedViewController ?? self).present(share, animated: true)
    }

    deinit {
        startupTimer?.invalidate()
        progressObservation?.invalidate()
    }
}
