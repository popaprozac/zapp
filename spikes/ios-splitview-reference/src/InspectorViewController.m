#import "InspectorViewController.h"
#import <WebKit/WebKit.h>

// ---------------------------------------------------------------------------
// InspectorViewController — the iOS-26 dedicated INSPECTOR column.
// Bright amber background + a big "INSPECTOR COLUMN" label so the smoke test can
// confirm the real inspector is rendering (not a blank). On iPad it appears as a
// hideable/draggable column beside the content; on iPhone (compact) UIKit
// auto-presents it as a sheet.
// ---------------------------------------------------------------------------

static NSString * const kInspectorHTML =
    @"<!doctype html><html><head>"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">"
    "<style>"
    "html,body{margin:0;height:100%%;font-family:-apple-system,sans-serif;}"
    "body{background:#ff9500;color:#1a1a1a;}"
    "#safetop{position:fixed;top:0;left:0;right:0;height:env(safe-area-inset-top);background:#ff3b30;}"
    "#safebottom{position:fixed;bottom:0;left:0;right:0;height:env(safe-area-inset-bottom);background:#34c759;}"
    "#safeleft{position:fixed;top:0;bottom:0;left:0;width:env(safe-area-inset-left);background:#ffcc00;}"
    "#saferight{position:fixed;top:0;bottom:0;right:0;width:env(safe-area-inset-right);background:#af52de;}"
    "#content{padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);}"
    "h1{margin:0;padding:12px 0 4px;font-size:28px;letter-spacing:.5px;}"
    "#section{font-size:18px;font-weight:600;opacity:.85;margin:0 0 12px;}"
    "p{font-size:15px;}"
    "</style></head><body>"
    "<div id=\"safetop\"></div>"
    "<div id=\"safebottom\"></div>"
    "<div id=\"safeleft\"></div>"
    "<div id=\"saferight\"></div>"
    "<div id=\"content\">"
    "<h1>INSPECTOR COLUMN</h1>"
    "<div id=\"section\">section: %SECTION%</div>"
    "<p>iOS-26 dedicated <strong>UISplitViewControllerColumnInspector</strong>, attached to a "
    "<strong>doubleColumn</strong> base (Primary=sidebar, Secondary=content).</p>"
    "<p>iPad: hideable/draggable column beside the content canvas.</p>"
    "<p>iPhone (compact): UIKit auto-presents this as a sheet.</p>"
    "</div>"
    "</body></html>";

@interface InspectorViewController ()
@property (nonatomic, strong) WKWebView *webView;
@end

@implementation InspectorViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Inspector";
    NSLog(@"[zapp-nav] inspector viewDidLoad (iOS-26 Inspector column)");

    // Edge-pinned WKWebView — same pattern as ContentViewController / DetailViewController.
    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.webView];

    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    // Substitute the current section (best-effort: read the split's title) so the
    // smoke can confirm this is the live inspector, not a placeholder.
    NSString *section = self.splitViewController.viewControllers.firstObject.title ?: @"—";
    NSString *html = [kInspectorHTML stringByReplacingOccurrencesOfString:@"%SECTION%"
                                                               withString:section];
    [self.webView loadHTMLString:html baseURL:nil];

    // Distinct toolbar item so the human can see UIKit swap toolbars per-VC.
    UIBarButtonItem *info = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"info.circle"]
                style:UIBarButtonItemStylePlain
               target:nil
               action:nil];
    self.navigationItem.rightBarButtonItems = @[ info ];
}

// TEMPORARY width-probe instrumentation (drag-pin research, 2026-07-01):
// log the live column width on every layout pass. There is no public
// current-width getter for the Inspector column, so this VC's view bounds
// (the column container) is the measure.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    NSLog(@"[zapp-nav] PROBE inspW=%.0f", self.view.bounds.size.width);
}

- (void)dealloc {
    NSLog(@"[zapp-nav] inspector dealloc (webview released)");
}

@end
