import Foundation

func redact(_ s: String) -> String {
    guard let re = try? NSRegularExpression(pattern: "(://|//)([^:/@\\s]+):([^@\\s]+)@") else { return s }
    let range = NSRange(s.startIndex..<s.endIndex, in: s)
    return re.stringByReplacingMatches(in: s, range: range, withTemplate: "$1$2:***@")
}

func sourceShare(_ source: String) -> String {
    var s = source
    if s.hasPrefix("//") { s = String(s.dropFirst(2)) }
    if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
    guard let slash = s.firstIndex(of: "/") else { return "" }
    return String(s[s.index(after: slash)...])
}

func isSafeMountPoint(_ raw: String) -> Bool {
    guard !raw.isEmpty else { return true }
    let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard p.hasPrefix("/Volumes/") else { return false }
    let comps = p.components(separatedBy: "/").filter { !$0.isEmpty }
    guard comps.count >= 2 else { return false }
    guard !comps.contains(where: { $0 == ".." || $0 == "." }) else { return false }
    return true
}

print("=== redact ===")
for s in [
    "mount_smbfs: //admin:s3cret@nas.local/HD failed",
    "smb://admin:s3cret@nas.local/HD",
    "https://me:s3cret@dav.example.com/dav",
    "//nas.local/HD no credential here",
    "error: authentication failed"
] { print("\(s)\n  -> \(redact(s))") }

print("\n=== sourceShare ===")
for s in [
    "//host/share",
    "//user@host/share",
    "//user:pass@host/share",
    "//host/",
    "//user@host:445/share",
    "//[2001:db8::1]/share",
    "//host/share/sub",
    "//user@host/dav/sub"
] { print("\(s) -> \"\(sourceShare(s))\"") }

print("\n=== isSafeMountPoint ===")
for p in ["", "/Volumes/HD", "/Volumes/HD/sub", "~/Volumes/x", "/Users/me/Volumes/x", "/etc", "/Volumes", "/Volumes/../etc"] {
    print("\"\(p)\" -> \(isSafeMountPoint(p))")
}
