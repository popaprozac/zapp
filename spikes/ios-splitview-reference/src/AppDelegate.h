#import <UIKit/UIKit.h>

@class SidebarViewController;
@class ContentViewController;

@interface AppDelegate : UIResponder <UIApplicationDelegate, UISplitViewControllerDelegate>

@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) SidebarViewController *sidebarVC;
@property (nonatomic, strong) ContentViewController *contentVC;
@property (nonatomic, strong) UINavigationController *sidebarNav;
@property (nonatomic, strong) UINavigationController *contentNav;

@end
