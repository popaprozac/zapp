#import "AppDelegate.h"
#import "SidebarViewController.h"
#import "ContentViewController.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];

    UISplitViewController *split =
        [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
    split.preferredDisplayMode = UISplitViewControllerDisplayModeOneBesideSecondary;
    split.preferredSplitBehavior = UISplitViewControllerSplitBehaviorTile;

    self.sidebarVC = [SidebarViewController new];
    self.contentVC = [ContentViewController new];

    // Wire the sidebar to the content VC so it can call -showSection:
    self.sidebarVC.contentVC = self.contentVC;

    self.sidebarNav  = [[UINavigationController alloc] initWithRootViewController:self.sidebarVC];
    self.contentNav  = [[UINavigationController alloc] initWithRootViewController:self.contentVC];

    [split setViewController:self.sidebarNav  forColumn:UISplitViewControllerColumnPrimary];
    [split setViewController:self.contentNav  forColumn:UISplitViewControllerColumnSecondary];

    split.delegate = self;

    self.window.rootViewController = split;
    [self.window makeKeyAndVisible];
    return YES;
}

// ── UISplitViewControllerDelegate ─────────────────────────────────────────────
// On iPhone, collapse both columns into one navigation stack.
// Return Primary so the user starts on the Sidebar (our owned-nav "sidebar-first" equivalent).
- (UISplitViewControllerColumn)splitViewController:(UISplitViewController *)svc
          topColumnForCollapsingToProposedTopColumn:(UISplitViewControllerColumn)proposedTopColumn {
    return UISplitViewControllerColumnPrimary;   // collapse → show Sidebar first
}

@end
