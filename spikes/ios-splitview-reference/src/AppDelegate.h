#import <UIKit/UIKit.h>

@class SidebarViewController;
@class ContentViewController;
@class InspectorViewController;

@interface AppDelegate : UIResponder <UIApplicationDelegate, UISplitViewControllerDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) SidebarViewController   *sidebarVC;
@property (nonatomic, strong) ContentViewController   *contentVC;
@property (nonatomic, strong) InspectorViewController *inspectorVC;
@property (nonatomic, strong) UINavigationController  *sidebarNav;
@property (nonatomic, strong) UINavigationController  *contentNav;
@property (nonatomic, strong) UINavigationController  *inspectorNav;
@property (nonatomic, strong) id navLogger; // NavLogger instance (logging-only delegate)

@end
