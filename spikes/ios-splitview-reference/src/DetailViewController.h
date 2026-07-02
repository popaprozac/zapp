#import <UIKit/UIKit.h>

// ---------------------------------------------------------------------------
// DetailViewController — "no-navbar" route (Q2).
// Hides the navigation bar for itself only (viewWillAppear/viewWillDisappear),
// implements the AHK-pattern robust swipe-back re-arm, and arbitrates against
// WKWebView's pan gesture so the edge-swipe can actually start.
// ---------------------------------------------------------------------------
@interface DetailViewController : UIViewController <UIGestureRecognizerDelegate>
@end
