#import "SidebarViewController.h"
#import "ContentViewController.h"

static NSArray<NSString *> *kSections;

@implementation SidebarViewController

+ (void)initialize {
    kSections = @[ @"Home", @"Library", @"Settings", @"About" ];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Sections";

    // A DISTINCT sidebar toolbar item — user can SEE UIKit swap per-VC
    UIBarButtonItem *compose = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemCompose
                             target:nil
                             action:nil];
    self.navigationItem.rightBarButtonItems = @[ compose ];
}

// ── UITableViewDataSource ─────────────────────────────────────────────────────

- (NSInteger)tableView:(UITableView *)tableView
 numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)kSections.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell =
        [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"cell"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    cell.textLabel.text = kSections[(NSUInteger)indexPath.row];
    return cell;
}

// ── UITableViewDelegate ───────────────────────────────────────────────────────

- (void)tableView:(UITableView *)tableView
didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSString *title = kSections[(NSUInteger)indexPath.row];

    // Update the persistent content VC payload
    [self.contentVC showSection:title];

    // Let UIKit handle the column reveal:
    //   • iPhone (collapsed): pushes contentNav's stack into the single stack
    //   • iPad (expanded): focuses the secondary column
    [self.splitViewController showColumn:UISplitViewControllerColumnSecondary];
}

@end
