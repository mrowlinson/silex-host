import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .optionIncludingWindow], kCGNullWindowID) as? [[String: Any]] ?? []
print("count=\(list.count)")
for w in list {
  let o = w[kCGWindowOwnerName as String] as? String ?? "?"
  let n = w[kCGWindowName as String] as? String ?? ""
  let wid = w[kCGWindowNumber as String] ?? 0
  print("\(wid) | \(o) | \(n.prefix(50))")
}
