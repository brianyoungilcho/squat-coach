import Foundation

// Standalone test runner for UpdaterLogic (compiled with Sources/UpdaterLogic.swift
// by `./build.sh --test`; no XCTest/Xcode). Exits non-zero on failure.

private var failures = 0
private func check(_ cond: Bool, _ msg: String) {
    print(cond ? "  ok  — \(msg)" : "  FAIL — \(msg)")
    if !cond { failures += 1 }
}

print("UpdaterLogic tests (self-update)")

// 1. Numeric version comparison, including multi-digit components.
do {
    check(UpdaterLogic.isNewer(latest: "0.3.0", current: "0.2.0"), "0.3.0 > 0.2.0")
    check(!UpdaterLogic.isNewer(latest: "0.2.0", current: "0.2.0"), "equal versions are not newer")
    check(!UpdaterLogic.isNewer(latest: "0.1.9", current: "0.2.0"), "older is not newer")
    check(UpdaterLogic.isNewer(latest: "0.10.0", current: "0.9.0"), "0.10.0 > 0.9.0 (numeric, not lexical)")
}

// 2. Release parsing: picks the exactly-named zip asset.
do {
    let json = """
    {"tag_name": "v0.3.0",
     "html_url": "https://github.com/brianyoungilcho/squat-coach/releases/tag/v0.3.0",
     "assets": [
       {"name": "Squat-Coach-0.3.0.zip.sha256", "browser_download_url": "https://example.com/wrong"},
       {"name": "Squat-Coach-0.3.0.zip", "browser_download_url": "https://example.com/right.zip"}
     ]}
    """.data(using: .utf8)!
    let r = UpdaterLogic.parseRelease(json)
    check(r?.version == "0.3.0", "tag v0.3.0 → version 0.3.0")
    check(r?.zipURL == "https://example.com/right.zip", "picks the exact zip asset, not the lookalike")
    check(r?.pageURL.contains("/releases/tag/v0.3.0") == true, "carries the release page URL")
}

// 3. No correctly-named asset → nil (caller falls back to the releases page).
do {
    let json = """
    {"tag_name": "v0.3.0", "html_url": "https://example.com",
     "assets": [{"name": "SomethingElse.zip", "browser_download_url": "https://example.com/other"}]}
    """.data(using: .utf8)!
    check(UpdaterLogic.parseRelease(json) == nil, "missing zip asset → nil")
}

// 4. Malformed payloads → nil, never a crash.
do {
    check(UpdaterLogic.parseRelease(Data("not json".utf8)) == nil, "garbage bytes → nil")
    check(UpdaterLogic.parseRelease(Data("{}".utf8)) == nil, "empty object → nil")
}

// 5. Download URLs are pinned to GitHub hosts, https only.
do {
    check(UpdaterLogic.isTrustedDownloadURL(URL(string: "https://github.com/x/y/releases/download/v1/z.zip")!),
          "github.com download URL is trusted")
    check(UpdaterLogic.isTrustedDownloadURL(URL(string: "https://objects.githubusercontent.com/abc")!),
          "objects.githubusercontent.com is trusted")
    check(!UpdaterLogic.isTrustedDownloadURL(URL(string: "https://evil.com/Squat-Coach-0.3.0.zip")!),
          "arbitrary host is rejected")
    check(!UpdaterLogic.isTrustedDownloadURL(URL(string: "https://github.com.evil.com/z.zip")!),
          "prefix-spoofed host is rejected")
    check(!UpdaterLogic.isTrustedDownloadURL(URL(string: "http://github.com/z.zip")!),
          "plain http is rejected")
}

print(failures == 0 ? "\nALL TESTS PASSED ✅" : "\n\(failures) TEST(S) FAILED ❌")
exit(failures == 0 ? 0 : 1)
