#import <UIKit/UIKit.h>

@interface ContentViewController : UIViewController

/// Update the displayed section (called by SidebarViewController on row selection).
- (void)showSection:(NSString *)name;

@end
