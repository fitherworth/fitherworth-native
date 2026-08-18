import Foundation
import WebKit

/// Proxies WKNavigationDelegate so Capacitor's own delegate keeps working
/// while every navigation event is persisted to NativeDiagnostics.
final class DiagnosticNavigationDelegate: NSObject, WKNavigationDelegate {
    weak var target: WKNavigationDelegate?

    init(target: WKNavigationDelegate?) {
        self.target = target
        super.init()
    }

    // Forward anything we don't implement to Capacitor's delegate.
    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return target?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if target?.responds(to: aSelector) == true { return target }
        return super.forwardingTarget(for: aSelector)
    }

    private func base(_ webView: WKWebView) -> [String: Any] {
        [
            "current_url": webView.url?.absoluteString ?? "nil",
            "url_kind": NativeDiagnostics.classify(webView.url),
            "is_loading": webView.isLoading,
            "progress": webView.estimatedProgress,
        ]
    }

    private func describe(_ error: Error) -> [String: Any] {
        let ns = error as NSError
        var out: [String: Any] = [
            "error_domain": ns.domain,
            "error_code": ns.code,
            "error_description": ns.localizedDescription,
        ]
        if let failing = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
            out["failing_url"] = failing
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            out["underlying_domain"] = underlying.domain
            out["underlying_code"] = underlying.code
            out["underlying_description"] = underlying.localizedDescription
        }
        if ns.domain == NSURLErrorDomain,
           let reason = ns.userInfo["_kCFStreamErrorCodeKey"] {
            out["tls_stream_error"] = String(describing: reason)
        }
        return out
    }

    // MARK: - Navigation lifecycle

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        NativeDiagnostics.shared.log("navigation_decide_policy", [
            "request_url": navigationAction.request.url?.absoluteString ?? "nil",
            "request_kind": NativeDiagnostics.classify(navigationAction.request.url),
            "nav_type": navigationAction.navigationType.rawValue,
        ])
        if let target, target.responds(to: #selector(WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:) as (WKNavigationDelegate) -> ((WKWebView, WKNavigationAction, @escaping (WKNavigationActionPolicy) -> Void) -> Void)?)) {
            target.webView?(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        var fields = base(webView)
        if let http = navigationResponse.response as? HTTPURLResponse {
            fields["status_code"] = http.statusCode
            fields["response_url"] = http.url?.absoluteString ?? "nil"
        }
        NativeDiagnostics.shared.log("navigation_response", fields)
        if let target, target.responds(to: #selector(WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:) as (WKNavigationDelegate) -> ((WKWebView, WKNavigationResponse, @escaping (WKNavigationResponsePolicy) -> Void) -> Void)?)) {
            target.webView?(webView, decidePolicyFor: navigationResponse, decisionHandler: decisionHandler)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        NativeDiagnostics.shared.log("navigation_start", base(webView))
        target?.webView?(webView, didStartProvisionalNavigation: navigation)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        NativeDiagnostics.shared.log("navigation_commit", base(webView))
        target?.webView?(webView, didCommit: navigation)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NativeDiagnostics.shared.log("navigation_finish", base(webView))
        target?.webView?(webView, didFinish: navigation)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        NativeDiagnostics.shared.log("navigation_provisional_fail",
                                     base(webView).merging(describe(error)) { a, _ in a })
        target?.webView?(webView, didFailProvisionalNavigation: navigation, withError: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NativeDiagnostics.shared.log("navigation_fail",
                                     base(webView).merging(describe(error)) { a, _ in a })
        target?.webView?(webView, didFail: navigation, withError: error)
    }

    func webView(_ webView: WKWebView,
                 didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        NativeDiagnostics.shared.log("auth_challenge", [
            "method": challenge.protectionSpace.authenticationMethod,
            "host": challenge.protectionSpace.host,
            "port": challenge.protectionSpace.port,
        ])
        if let target, target.responds(to: #selector(WKNavigationDelegate.webView(_:didReceive:completionHandler:))) {
            target.webView?(webView, didReceive: challenge, completionHandler: completionHandler)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NativeDiagnostics.shared.log("webcontent_process_terminated", base(webView).merging([
            "reason": "WKWebView content process crashed or was jetsammed",
        ]) { a, _ in a })
        target?.webViewWebContentProcessDidTerminate?(webView)
    }
}
