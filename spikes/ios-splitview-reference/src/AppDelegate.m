#import "AppDelegate.h"
#import "SidebarViewController.h"
#import "ContentViewController.h"
#import "InspectorViewController.h"

// ---------------------------------------------------------------------------
// NavLogger — instruments every push/pop on any navigation controller with
// [zapp-nav] prefixed NSLog lines. Kept separate from AppDelegate.
// ---------------------------------------------------------------------------
@interface NavLogger : NSObject <UINavigationControllerDelegate>
@property (nonatomic, copy) NSString *label; // e.g. "content" or "inspector"
@end

@implementation NavLogger

- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    NSLog(@"[zapp-nav] willShow(%@) vc=%@ navBarHidden=%d stack=%lu",
          self.label,
          NSStringFromClass(viewController.class),
          (int)navigationController.navigationBarHidden,
          (unsigned long)navigationController.viewControllers.count);
}

- (void)navigationController:(UINavigationController *)navigationController
       didShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated {
    NSLog(@"[zapp-nav] didShow(%@) vc=%@ navBarHidden=%d stack=%lu",
          self.label,
          NSStringFromClass(viewController.class),
          (int)navigationController.navigationBarHidden,
          (unsigned long)navigationController.viewControllers.count);
}

@end

// ---------------------------------------------------------------------------

// ── E3a hidden-Primary variant (no-sidebar window shape) ──────────────────
// Build with:  EXTRA_CFLAGS=-DSPLITREF_NO_SIDEBAR=1 ./build.sh   (or edit the
// default below). Proves a doubleColumn split whose Primary is an EMPTY VC
// held permanently hidden, so the iOS-26 Inspector column has a split to
// attach to on windows that declare no sidebar.
#ifndef SPLITREF_NO_SIDEBAR
#define SPLITREF_NO_SIDEBAR 0
#endif

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    // ── EXPERIMENT: doubleColumn base + iOS-26 Inspector column ────────────────
    // HYPOTHESIS: a 3-pane app (sidebar + content + inspector) is best modelled
    // as a doubleColumn split whose Secondary is the PERMANENT canvas (content),
    // with the iOS-26 dedicated *Inspector* column attached on top — rather than
    // a tripleColumn split abusing Supplementary as content.
    //
    // Column mapping (doubleColumn):
    //   Primary   = sidebar   (list)
    //   Secondary = content   (permanent canvas — NOT Supplementary anymore)
    //   Inspector = inspector (iOS-26 hideable/draggable column; auto-sheet on compact)
    //
    // On iPad: OneBesideSecondary + Tile → sidebar | content, with the inspector
    //          appearing as a third tiled/draggable column when shown.
    // On iPhone (compact): UIKit auto-presents the Inspector column as a sheet.
    // ─────────────────────────────────────────────────────────────────────────
    UISplitViewController *split =
        [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];

    // doubleColumn base: one column beside the permanent secondary (content).
    split.preferredDisplayMode   = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;

#if SPLITREF_NO_SIDEBAR
    // E3a: no sidebar content — hold Primary permanently hidden so only
    // Secondary (content) + Inspector (26+) are ever visible/reachable.
    split.preferredDisplayMode  = UISplitViewControllerDisplayModeSecondaryOnly;
    split.presentsWithGesture   = NO;
    if (@available(iOS 14.0, *)) {
        split.showsSecondaryOnlyButton = NO;
    }
#endif

#if !SPLITREF_NO_SIDEBAR
    self.sidebarVC   = [SidebarViewController new];
#endif
    self.contentVC   = [ContentViewController new];
    self.inspectorVC = [InspectorViewController new];

#if !SPLITREF_NO_SIDEBAR
    // Wire the sidebar to the content VC so it can call -showSection:
    self.sidebarVC.contentVC = self.contentVC;
#endif

#if !SPLITREF_NO_SIDEBAR
    self.sidebarNav   = [[UINavigationController alloc] initWithRootViewController:self.sidebarVC];
#endif
    self.contentNav   = [[UINavigationController alloc] initWithRootViewController:self.contentVC];
    self.inspectorNav = [[UINavigationController alloc] initWithRootViewController:self.inspectorVC];

    // NavLogger on both content and inspector — we want to see what UIKit does
    // with each nav stack during collapse / inspector present on iPhone.
    NavLogger *contentLogger = [NavLogger new];
    contentLogger.label = @"content";
    self.contentNav.delegate = contentLogger;

    NavLogger *inspectorLogger = [NavLogger new];
    inspectorLogger.label = @"inspector";
    self.inspectorNav.delegate = inspectorLogger;

    // Retain both loggers on self so they outlive the split setup.
    self.navLogger = @[ contentLogger, inspectorLogger ]; // stash both

    // ── doubleColumn column assignment ────────────────────────────────────────
    // Primary   = sidebar list (or, in the E3a no-sidebar variant, an empty VC
    //             held permanently hidden — see SPLITREF_NO_SIDEBAR above)
    // Secondary = content pane (the PERMANENT canvas)
#if !SPLITREF_NO_SIDEBAR
    [split setViewController:self.sidebarNav forColumn:UISplitViewControllerColumnPrimary];
#else
    // E3a: empty Primary, no nav wrap, no content — never meant to be seen.
    UIViewController *emptyPrimary = [[UIViewController alloc] init];
    emptyPrimary.view.backgroundColor = [UIColor clearColor];
    [split setViewController:emptyPrimary forColumn:UISplitViewControllerColumnPrimary];
#endif
    [split setViewController:self.contentNav forColumn:UISplitViewControllerColumnSecondary];

    // ── iOS-26 Inspector column ───────────────────────────────────────────────
    // First-class hideable/draggable inspector, distinct from Secondary. On
    // compact width UIKit auto-presents it as a sheet. Below iOS 26 we skip this
    // and the ContentVC toggle summons the inspector as a modal sheet instead.
    if (@available(iOS 26.0, *)) {
        [split setViewController:self.inspectorNav
                      forColumn:UISplitViewControllerColumnInspector];
        // Give the inspector a sensible default width so it's clearly visible.
        split.preferredInspectorColumnWidthFraction = 0.30;
    }

    split.delegate = self;

    self.window.rootViewController = split;
    [self.window makeKeyAndVisible];

    // Log the resolved style and confirm the Inspector column VC is actually
    // attached (non-nil) — the crux of the experiment.
    NSLog(@"[zapp-nav] launch DOUBLECOLUMN split style=%ld preferredDisplayMode=%ld preferredSplitBehavior=%ld",
          (long)split.style, (long)split.preferredDisplayMode, (long)split.preferredSplitBehavior);
    if (@available(iOS 26.0, *)) {
        UIViewController *inspCol =
            [split viewControllerForColumn:UISplitViewControllerColumnInspector];
        NSLog(@"[zapp-nav] inspector-column VC after setup = %@ (non-nil=%d)",
              NSStringFromClass(inspCol.class), (int)(inspCol != nil));
    } else {
        NSLog(@"[zapp-nav] iOS<26 — no Inspector column; toggle will present a modal sheet");
    }

    return YES;
}

// ── UISplitViewControllerDelegate ─────────────────────────────────────────────
// Called when the split collapses (iPhone / compact-width).
// We return Primary so the user starts on the Sidebar.
// On a doubleColumn split UIKit's default proposed top column on collapse is
// Secondary (content). We OVERRIDE to Primary so the iPhone cold-launch shows the
// Sidebar; the Inspector column does NOT participate in this collapsed stack —
// on compact width UIKit presents it as an auto-sheet instead.
// ─────────────────────────────────────────────────────────────────────────────
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
          topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    NSLog(@"[zapp-nav] collapse proposed=%ld → returning Primary (Primary=%ld Secondary=%ld compact=%ld)",
          (long)proposedTopColumn,
          (long)UISplitViewControllerColumnPrimary,
          (long)UISplitViewControllerColumnSecondary,
          (long)UISplitViewControllerColumnCompact);
    // Collapse to Primary (sidebar) so iPhone cold-launch shows the sidebar.
    return UISplitViewControllerColumnPrimary;
}

// Called when the split re-expands (rotation to landscape / iPad).
- (void)splitViewController:(UISplitViewController *)svc
    willChangeToPrimaryDisplayMode:(UISplitViewControllerDisplayMode)displayMode {
    NSLog(@"[zapp-nav] expand → displayMode=%ld", (long)displayMode);
}

@end
