import AppKit
for s in NSScreen.screens { print(s.frame, s.visibleFrame, s.backingScaleFactor) }
