#import "DetailViewController.h"

@implementation DetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Detail";
    self.view.backgroundColor = [UIColor systemIndigoColor];

    UILabel *label = [[UILabel alloc] init];
    label.text = @"Pushed detail — native back button\n+ edge-swipe should both work\nwith ZERO custom code.";
    label.font = [UIFont systemFontOfSize:18 weight:UIFontWeightRegular];
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.whiteColor;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [label.leadingAnchor  constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor  constant:24],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor   constant:-24],
    ]];

    // ONE DISTINCT detail toolbar item — UIKit replaces the content's two items with this one
    UIBarButtonItem *trash = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                             target:nil
                             action:nil];
    self.navigationItem.rightBarButtonItems = @[ trash ];

    // NO custom back handling — UIKit's UINavigationController provides:
    //   • the "<Content" back button in the navigation bar
    //   • the interactive edge-swipe-back gesture
    // entirely for free.
}

@end
