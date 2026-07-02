#import "ContentViewController.h"
#import "DetailViewController.h"
#import "InspectorViewController.h"
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

    self.title = @"Home";
    self.currentSection = @"Home";

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

    // ── Inspector BUTTON on the Content VC ────────────────────────────────────
    // On iOS 26 this toggles the dedicated Inspector column (show/hideColumn:).
    // On iPad (regular) it slides the inspector column in/out beside the content;
    // on iPhone (compact) UIKit auto-presents that same column as a sheet.
    // Below iOS 26 the button presents a modal InspectorViewController sheet.
    // `sidebar.right` reads as "panel on the trailing edge" — the platform idiom
    // for an inspector toggle.
    UIBarButtonItem *inspector = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"sidebar.right"]
                style:UIBarButtonItemStylePlain
               target:self
               action:@selector(toggleInspector)];

    // TEMPORARY width-probe buttons (drag-pin research, 2026-07-01):
    // P1 = clamp-nudge, P2 = hide/show cycle. Open the inspector and DRAG the
    // seam first, then press. Watch the [zapp-nav] PROBE inspW= log lines.
    UIBarButtonItem *p1 = [[UIBarButtonItem alloc]
        initWithTitle:@"P1" style:UIBarButtonItemStylePlain
               target:self action:@selector(probeClampNudge)];
    UIBarButtonItem *p2 = [[UIBarButtonItem alloc]
        initWithTitle:@"P2" style:UIBarButtonItemStylePlain
               target:self action:@selector(probeHideShowCycle)];

    self.navigationItem.rightBarButtonItems = @[ inspector, share, filter, p1, p2 ];

    // Do NOT set a leftBarButtonItem — let UISplitViewController/UINavigationController
    // provide its displayModeButtonItem / back button automatically.
}

// ---------------------------------------------------------------------------
// Inspector button handler — the crux of the experiment.
//
//   • iOS 26+: toggle the dedicated Inspector column via show/hideColumn:.
//              Visibility is read with the clean -isShowingColumn: API (iOS 26),
//              so no BOOL bookkeeping is needed. On iPad the column slides in/out
//              beside the content; on iPhone (compact) UIKit auto-presents that
//              same Inspector column as a sheet — we don't manage the sheet.
//   • pre-26 fallback: present InspectorViewController modally, wrapped in a nav
//              controller, as a sheet with medium+large detents and a grabber.
// ---------------------------------------------------------------------------
- (void)toggleInspector {
    UISplitViewController *split = self.splitViewController;

    if (@available(iOS 26.0, *)) {
        BOOL showing = [split isShowingColumn:UISplitViewControllerColumnInspector];
        if (showing) {
            NSLog(@"[zapp-nav] inspector-button (iOS26) showing=1 → hideColumn:Inspector (collapsed=%d)",
                  (int)split.isCollapsed);
            [split hideColumn:UISplitViewControllerColumnInspector];
        } else {
            NSLog(@"[zapp-nav] inspector-button (iOS26) showing=0 → showColumn:Inspector (collapsed=%d)",
                  (int)split.isCollapsed);
            [split showColumn:UISplitViewControllerColumnInspector];
        }
        return;
    }

    // ── pre-26 fallback: modal inspector sheet ────────────────────────────────
    NSLog(@"[zapp-nav] inspector-button (pre-iOS26) → present modal inspector sheet");
    InspectorViewController *insp = [InspectorViewController new];
    UINavigationController *nav =
        [[UINavigationController alloc] initWithRootViewController:insp];
    nav.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        UISheetPresentationController *sheet = nav.sheetPresentationController;
        sheet.detents = @[ UISheetPresentationControllerDetent.mediumDetent,
                           UISheetPresentationControllerDetent.largeDetent ];
        sheet.prefersGrabberVisible = YES;
    }
    [self presentViewController:nav animated:YES completion:nil];
}

// ---------------------------------------------------------------------------
// TEMPORARY width-probe handlers (drag-pin research, 2026-07-01).
//
// After the USER drags the inspector seam, UIKit stops enforcing
// preferredInspectorColumnWidth (internal enforcingColumnPreferences flag
// flips off; the dragged width lives in private state and re-applies on every
// layout). Question: can PUBLIC API re-assert a programmatic width?
//
//   P1 clamp-nudge : min==max==target (known to beat the pin) → layout →
//                    1s later restore flexible min/max. If inspW HOLDS the
//                    target after restore, the workaround exists; if it snaps
//                    back to the dragged width, the pin survives clamping.
//   P2 hide/show   : hideColumn: → set preferred while hidden → showColumn:.
//                    Tests whether column re-presentation re-enters the
//                    enforce-preferences path (distinct from displayMode
//                    toggles, which never hide the Inspector column).
//   P3 (no code)   : P1/P2 leave preferredInspectorColumnWidth armed at the
//                    target — after a FAILED P1/P2, TAP the seam handle:
//                    UIKit's built-in snap-to-preferred tap gesture is the
//                    user-side reset (_handleResizeColumnToPreferredSize…).
//
// Verdict comes from the [zapp-nav] PROBE inspW= lines (InspectorViewController
// logs every layout pass).
// ---------------------------------------------------------------------------
- (void)probeClampNudge {
    if (@available(iOS 26.0, *)) {
        UISplitViewController *split = self.splitViewController;
        const CGFloat target = 240.0;
        NSLog(@"[zapp-nav] PROBE P1 start target=%.0f prefW=%.1f min=%.1f max=%.1f",
              target, split.preferredInspectorColumnWidth,
              split.minimumInspectorColumnWidth, split.maximumInspectorColumnWidth);
        split.preferredInspectorColumnWidth = target;
        split.minimumInspectorColumnWidth = target;
        split.maximumInspectorColumnWidth = target;
        [split.view setNeedsLayout];
        [split.view layoutIfNeeded];
        NSLog(@"[zapp-nav] PROBE P1 clamped — restoring min=180 max=500 in 1s");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            split.minimumInspectorColumnWidth = 180.0;
            split.maximumInspectorColumnWidth = 500.0;
            [split.view setNeedsLayout];
            [split.view layoutIfNeeded];
            NSLog(@"[zapp-nav] PROBE P1 restored — inspW=%.0f now: holding 240 = WORKAROUND WORKS; back at dragged width = pin survives",
                  target);
        });
    } else {
        NSLog(@"[zapp-nav] PROBE P1 requires iOS 26");
    }
}

- (void)probeHideShowCycle {
    if (@available(iOS 26.0, *)) {
        UISplitViewController *split = self.splitViewController;
        const CGFloat target = 360.0;
        NSLog(@"[zapp-nav] PROBE P2 start target=%.0f prefW=%.1f — hiding column",
              target, split.preferredInspectorColumnWidth);
        [split hideColumn:UISplitViewControllerColumnInspector];
        split.preferredInspectorColumnWidth = target;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSLog(@"[zapp-nav] PROBE P2 showing column (prefW=%.1f) — inspW at 360 = WORKAROUND WORKS; dragged width = pin survives hide/show",
                  split.preferredInspectorColumnWidth);
            [split showColumn:UISplitViewControllerColumnInspector];
        });
    } else {
        NSLog(@"[zapp-nav] PROBE P2 requires iOS 26");
    }
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
    NSLog(@"[zapp-nav] showSection %@", name);

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
    NSUInteger stackCount = self.navigationController.viewControllers.count + 1;
    NSLog(@"[zapp-nav] push detail stack=%lu", (unsigned long)stackCount);
    // Idiomatic push — UIKit gives the back button and edge-swipe for free.
    [self.navigationController pushViewController:[DetailViewController new] animated:YES];
}

@end
