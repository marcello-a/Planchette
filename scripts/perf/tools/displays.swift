import CoreGraphics
var ids = [CGDirectDisplayID](repeating: 0, count: 16)
var active: UInt32 = 0, online: UInt32 = 0
CGGetActiveDisplayList(16, &ids, &active)
CGGetOnlineDisplayList(16, &ids, &online)
print("active=\(active) online=\(online) asleep=\(CGDisplayIsAsleep(CGMainDisplayID()))")
