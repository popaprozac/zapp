#import "ContentViewController.h"
#import "DetailViewController.h"
#import <WebKit/WebKit.h>

// ---------------------------------------------------------------------------
// HTML template shared for the safe-area visualiser.
// %BG%    → background colour (CSS colour string)
// %TITLE% → heading text
// %LINK%  → optional anchor / note injected below the heading
// ---------------------------------------------------------------------------
static NSString * const kSafeAreaHTMLTemplate =
    @"<!doctype html><html><head>"
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, viewport-fit=cover\">"
    "<style>"
    "html,body{margin:0;height:100%%;font-family:-apple-system,sans-serif;}"
    "body{background:%BG%;}"
    "#safetop{position:fixed;top:0;left:0;right:0;height:env(safe-area-inset-top);background:#ff3b30;}"
    "#safebottom{position:fixed;bottom:0;left:0;right:0;height:env(safe-area-inset-bottom);background:#34c759;}"
    "#safeleft{position:fixed;top:0;bottom:0;left:0;width:env(safe-area-inset-left);background:#ff9500;}"
    "#saferight{position:fixed;top:0;bottom:0;right:0;width:env(safe-area-inset-right);background:#af52de;}"
    "#content{padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);}"
    "h1{margin:0;padding:8px 0;}"
    "#readout{font-size:14px;white-space:pre;opacity:.85;}"
    "a{font-size:20px;display:inline-block;margin-top:16px;}"
    "</style></head><body>"
    "<div id=\"safetop\"></div>"
    "<div id=\"safebottom\"></div>"
    "<div id=\"safeleft\"></div>"
    "<div id=\"saferight\"></div>"
    "<div id=\"content\">"
    "<h1 id=\"section\">%TITLE%</h1>"
    "<div id=\"readout\">reading safe-area\xe2\x80\xa6</div>"
    "%LINK%"
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

@interface ContentViewController () <WKScriptMessageHandler>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, copy)   NSString  *currentSection;
@end

@implementation ContentViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Content";
    self.currentSection = @"(select a section)";

    // ------------------------------------------------------------------
    // Full-bleed WKWebView pinned to EDGES (not safe-area guide).
    // This is intentional: we want to observe UIKit's DEFAULT behaviour,
    // not paper over it with safe-area constraints.
    // ------------------------------------------------------------------
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];

    // Register the "nav" message handler so JS can trigger native push.
    [config.userContentController addScriptMessageHandler:self name:@"nav"];

    self.webView = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config];
    self.webView.translatesAutoresizingMaskIntoConstraints = NO;

    // Let the webview's scroll view extend behind the nav bar by default.
    // (We deliberately do NOT set scrollView.contentInsetAdjustmentBehavior
    //  so UIKit uses the default UIScrollViewContentInsetAdjustmentAutomatic —
    //  this is what Phase 2 measures.)
    [self.view addSubview:self.webView];

    // Pin to view EDGES — NOT safe-area layout guide.
    [NSLayoutConstraint activateConstraints:@[
        [self.webView.leadingAnchor  constraintEqualToAnchor:self.view.leadingAnchor],
        [self.webView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.webView.topAnchor      constraintEqualToAnchor:self.view.topAnchor],
        [self.webView.bottomAnchor   constraintEqualToAnchor:self.view.bottomAnchor],
    ]];

    [self loadHTML];

    // ------------------------------------------------------------------
    // Per-VC toolbar items — identical to Phase 1.
    // UIKit swaps these in/out as the VC enters/leaves the top of the stack.
    // ------------------------------------------------------------------
    UIBarButtonItem *filter = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"]
                style:UIBarButtonItemStylePlain
               target:nil
               action:nil];
    UIBarButtonItem *share = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAction
                             target:nil
                             action:nil];
    self.navigationItem.rightBarButtonItems = @[ share, filter ];

    // Do NOT set a leftBarButtonItem — let UISplitViewController/UINavigationController
    // provide its displayModeButtonItem / back button automatically.
}

// ---------------------------------------------------------------------------
// Build and load the HTML with the current section substituted in.
// ---------------------------------------------------------------------------
- (void)loadHTML {
    NSString *link =
        @"<a href=\"#\" "
        "onclick=\"webkit.messageHandlers.nav.postMessage('detail');return false\">"
        "Push detail \xe2\x86\x92</a>";

    NSString *html = kSafeAreaHTMLTemplate;
    html = [html stringByReplacingOccurrencesOfString:@"%BG%"    withString:@"#4db6ac"];
    html = [html stringByReplacingOccurrencesOfString:@"%TITLE%" withString:self.currentSection];
    html = [html stringByReplacingOccurrencesOfString:@"%LINK%"  withString:link];

    [self.webView loadHTMLString:html baseURL:nil];
}

// ---------------------------------------------------------------------------
// Called by SidebarViewController on row selection.
// ---------------------------------------------------------------------------
- (void)showSection:(NSString *)name {
    self.title = name;
    self.currentSection = name;

    // If the webview is already loaded, update in-place via JS (avoids a full
    // reload that would flicker the visualiser). Fall back to full reload.
    NSString *escaped = [name stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString *js = [NSString stringWithFormat:
        @"(function(){"
        "var el=document.getElementById('section');"
        "if(el){el.textContent='%@';return 'updated';}"
        "return 'not-found';})()", escaped];

    [self.webView evaluateJavaScript:js completionHandler:^(id result, NSError *err) {
        if (err || ![@"updated" isEqualToString:result]) {
            // Page not ready yet — fall back to full reload.
            [self loadHTML];
        }
    }];
}

// ---------------------------------------------------------------------------
// WKScriptMessageHandler — "nav" handler from JS.
// JS calls:  webkit.messageHandlers.nav.postMessage("detail")
// ---------------------------------------------------------------------------
- (void)userContentController:(WKUserContentController *)controller
      didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"nav"] &&
        [message.body isEqualToString:@"detail"]) {
        [self pushDetail];
    }
}

- (void)pushDetail {
    // Idiomatic push — UIKit gives the back button and edge-swipe for free.
    [self.navigationController pushViewController:[DetailViewController new] animated:YES];
}

@end
