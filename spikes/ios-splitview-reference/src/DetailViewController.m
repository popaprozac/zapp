#import "DetailViewController.h"
#import <WebKit/WebKit.h>

// The HTML template is defined in ContentViewController.m; re-declare just
// the extern to avoid duplicate symbol. We embed it directly here instead.
// Detail uses its own simpler HTML (no "nav" handler needed — back is native).

static NSString * const kDetailHTML =
    @"<!doctype html><html><head>"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">"
    "<style>"
    "html,body{margin:0;height:100%%;font-family:-apple-system,sans-serif;}"
    "body{background:#5e5ce6;}"
    "#safetop{position:fixed;top:0;left:0;right:0;height:env(safe-area-inset-top);background:#ff3b30;}"
    "#safebottom{position:fixed;bottom:0;left:0;right:0;height:env(safe-area-inset-bottom);background:#34c759;}"
    "#safeleft{position:fixed;top:0;bottom:0;left:0;width:env(safe-area-inset-left);background:#ff9500;}"
    "#saferight{position:fixed;top:0;bottom:0;right:0;width:env(safe-area-inset-right);background:#af52de;}"
    "#content{padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);color:#fff;}"
    "h1{margin:0;padding:8px 0;}"
    "#readout{font-size:14px;white-space:pre;opacity:.85;}"
    "p{font-size:16px;}"
    "</style></head><body>"
    "<div id=\"safetop\"></div>"
    "<div id=\"safebottom\"></div>"
    "<div id=\"safeleft\"></div>"
    "<div id=\"saferight\"></div>"
    "<div id=\"content\">"
    "<h1>Detail</h1>"
    "<p>Native back button + edge-swipe should still work \xe2\x80\x94 "
    "and this webview should inset below the bar if UIKit propagates safe-area.</p>"
    "<div id=\"readout\">reading safe-area\xe2\x80\xa6</div>"
    "</div>"
    "<script>"
    "function show(){"
    "var p=document.createElement('div');"
    "p.style.cssText='position:fixed;top:env(safe-area-inset-top);left:env(safe-area-inset-left);';"
    "document.body.appendChild(p);"
    "var r=p.getBoundingClientRect();"
    "document.getElementById('readout').textContent="
    "'safe-area-inset-top  = '+Math.round(r.top)+'px\\n'"
    "+'safe-area-inset-left = '+Math.round(r.left)+'px\\n'"
    "+'(red band above = top inset; if 0 the content bleeds UNDER the nav bar)';"
    "p.remove();}"
    "window.addEventListener('load',show);"
    "window.addEventListener('resize',show);"
    "setTimeout(show,300);"
    "</script>"
    "</body></html>";

// ---------------------------------------------------------------------------

@implementation DetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Detail";

    // ------------------------------------------------------------------
    // Full-bleed WKWebView pinned to EDGES (not safe-area guide).
    // Same intent as ContentViewController: observe UIKit default behaviour.
    // ------------------------------------------------------------------
    WKWebView *webView = [[WKWebView alloc] initWithFrame:CGRectZero];
    webView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:webView];

    // Pin to view EDGES — NOT safe-area layout guide.
    [NSLayoutConstraint activateConstraints:@[
        [webView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [webView.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [webView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [webView loadHTMLString:kDetailHTML baseURL:nil];

    // ------------------------------------------------------------------
    // ONE DISTINCT detail toolbar item — UIKit replaces the content's two
    // items with this one (identical to Phase 1, proves toolbar still works).
    // ------------------------------------------------------------------
    UIBarButtonItem *trash = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                             target:nil
                             action:nil];
    self.navigationItem.rightBarButtonItems = @[ trash ];

    // NO custom back handling — UIKit's UINavigationController provides:
    //   • the "<Content" back button in the navigation bar
    //   • the interactive edge-swipe-back gesture
    // entirely for free, just as in Phase 1.
}

@end
