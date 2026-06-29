#import "ContentViewController.h"
#import "DetailViewController.h"

@interface ContentViewController ()
@property (nonatomic, strong) UILabel *sectionLabel;
@end

@implementation ContentViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    self.title = @"Content";
    self.view.backgroundColor = [UIColor systemTealColor];

    // Section label
    self.sectionLabel = [[UILabel alloc] init];
    self.sectionLabel.text = @"(select a section)";
    self.sectionLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightMedium];
    self.sectionLabel.textAlignment = NSTextAlignmentCenter;
    self.sectionLabel.textColor = [UIColor labelColor];
    self.sectionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.sectionLabel];

    // "Push detail →" button
    UIButton *pushBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [pushBtn setTitle:@"Push detail →" forState:UIControlStateNormal];
    pushBtn.titleLabel.font = [UIFont systemFontOfSize:20];
    pushBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [pushBtn addTarget:self
                action:@selector(pushDetail)
      forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:pushBtn];

    [NSLayoutConstraint activateConstraints:@[
        [self.sectionLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.sectionLabel.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor
                                                        constant:-40],
        [self.sectionLabel.leadingAnchor  constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor  constant:16],
        [self.sectionLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor   constant:-16],

        [pushBtn.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [pushBtn.topAnchor     constraintEqualToAnchor:self.sectionLabel.bottomAnchor constant:24],
    ]];

    // TWO DISTINCT content toolbar items — UIKit will swap these in when this VC is on screen
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

    // Do NOT set a leftBarButtonItem — let UISplitViewController provide its
    // displayModeButtonItem / back button automatically.
}

- (void)showSection:(NSString *)name {
    self.title = name;
    self.sectionLabel.text = name;
}

- (void)pushDetail {
    DetailViewController *d = [DetailViewController new];
    // UIKit gives back button + interactive edge-swipe-back FOR FREE
    [self.navigationController pushViewController:d animated:YES];
}

@end
