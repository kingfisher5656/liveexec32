#pragma once

@import CoreGraphics;

__BEGIN_DECLS

// Copies a guest-backed bitmap context's host shadow pixels back into guest
// memory. This is shared by drawing bridges outside CoreGraphics itself.
void LC32CoreGraphicsSyncBitmapBacking(CGContextRef context);
void LC32CoreGraphicsPrepareBitmapBacking(CGContextRef context);

// Bracket every host-to-guest Objective-C call. A guest pointer handed out by
// CGBitmapContextGetData for a host-owned context (a drawRect: backing store)
// is copied back into the host pixels when the call that requested it
// returns.
int LC32CoreGraphicsEnterGuestCallback(void);
void LC32CoreGraphicsLeaveGuestCallback(int depth);
// Write back and drop the guest mirror of a host-owned context early (used
// when an image context ends outside any guest callback).
void LC32CoreGraphicsReleaseHostedMirror(CGContextRef context);

__END_DECLS
