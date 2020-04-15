//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

#import "NotificationSettingsViewController.h"
#import "NotificationSettingsOptionsViewController.h"
#import "OWSSoundSettingsViewController.h"
#import <SignalMessaging/Environment.h>
#import <SignalMessaging/OWSPreferences.h>
#import <SignalMessaging/OWSSounds.h>
#import <SignalMessaging/UIUtil.h>
#import "Session-Swift.h"

@implementation NotificationSettingsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];

    [self updateTableContents];
    
    // Loki: Set gradient background
    self.tableView.backgroundColor = UIColor.clearColor;
    LKGradient *gradient = LKGradients.defaultLokiBackground;
    self.view.backgroundColor = UIColor.clearColor;
    [self.view setGradient:gradient];
    
    // Loki: Set navigation bar background color
    UINavigationBar *navigationBar = self.navigationController.navigationBar;
    [navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    navigationBar.shadowImage = [UIImage new];
    [navigationBar setTranslucent:NO];
    navigationBar.barTintColor = LKColors.navigationBarBackground;
    
    // Loki: Customize title
    UILabel *titleLabel = [UILabel new];
    titleLabel.text = NSLocalizedString(@"Notifications", @"");
    titleLabel.textColor = LKColors.text;
    titleLabel.font = [UIFont boldSystemFontOfSize:LKValues.veryLargeFontSize];
    self.navigationItem.titleView = titleLabel;
    
    // Loki: Set up back button
    UIBarButtonItem *backButton = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Back", "") style:UIBarButtonItemStylePlain target:nil action:nil];
    backButton.tintColor = LKColors.text;
    self.navigationItem.backBarButtonItem = backButton;
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    [self updateTableContents];
}

#pragma mark - Table Contents

- (void)updateTableContents
{
    OWSTableContents *contents = [OWSTableContents new];

    __weak NotificationSettingsViewController *weakSelf = self;

    OWSPreferences *prefs = Environment.shared.preferences;

    OWSTableSection *strategySection = [OWSTableSection new];
    strategySection.headerTitle = NSLocalizedString(@"Notification Strategy", @"");
    [strategySection addItem:[OWSTableItem switchItemWithText:NSLocalizedString(@"Use APNs", @"")
                               accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"push_notification_strategy")
                               isOnBlock:^{
                                   return [NSUserDefaults.standardUserDefaults boolForKey:@"isUsingFullAPNs"];
                               }
                               isEnabledBlock:^{
                                   return YES;
                               }
                               target:weakSelf
                               selector:@selector(didToggleAPNsSwitch:)]];
    strategySection.footerTitle = NSLocalizedString(@"Session will use the Apple Push Notification Service to receive push notifications. You’ll be notified of new messages reliably and immediately. Using APNs means that this device will communicate directly with Apple’s servers to retrieve push notifications, which will expose your IP address to Apple. Your messages will still be onion-routed and end-to-end encrypted, so the contents of your messages will remain completely private.", @"");
    [contents addSection:strategySection];

    // Sounds section.

    OWSTableSection *soundsSection = [OWSTableSection new];
    soundsSection.headerTitle
        = NSLocalizedString(@"SETTINGS_SECTION_SOUNDS", @"Header Label for the sounds section of settings views.");
    [soundsSection
        addItem:[OWSTableItem disclosureItemWithText:
                                  NSLocalizedString(@"SETTINGS_ITEM_NOTIFICATION_SOUND",
                                      @"Label for settings view that allows user to change the notification sound.")
                                          detailText:[OWSSounds displayNameForSound:[OWSSounds globalNotificationSound]]
                             accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"message_sound")
                                         actionBlock:^{
                                             OWSSoundSettingsViewController *vc = [OWSSoundSettingsViewController new];
                                             [weakSelf.navigationController pushViewController:vc animated:YES];
                                         }]];

    NSString *inAppSoundsLabelText = NSLocalizedString(@"NOTIFICATIONS_SECTION_INAPP",
        @"Table cell switch label. When disabled, Signal will not play notification sounds while the app is in the "
        @"foreground.");
    [soundsSection addItem:[OWSTableItem switchItemWithText:inAppSoundsLabelText
                               accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"in_app_sounds")
                               isOnBlock:^{
                                   return [prefs soundInForeground];
                               }
                               isEnabledBlock:^{
                                   return YES;
                               }
                               target:weakSelf
                               selector:@selector(didToggleSoundNotificationsSwitch:)]];
    [contents addSection:soundsSection];

    OWSTableSection *backgroundSection = [OWSTableSection new];
    backgroundSection.headerTitle = NSLocalizedString(@"SETTINGS_NOTIFICATION_CONTENT_TITLE", @"table section header");
    [backgroundSection
        addItem:[OWSTableItem
                     disclosureItemWithText:NSLocalizedString(@"NOTIFICATIONS_SHOW", nil)
                                 detailText:[prefs nameForNotificationPreviewType:[prefs notificationPreviewType]]
                    accessibilityIdentifier:ACCESSIBILITY_IDENTIFIER_WITH_NAME(self, @"options")
                                actionBlock:^{
                                    NotificationSettingsOptionsViewController *vc =
                                        [NotificationSettingsOptionsViewController new];
                                    [weakSelf.navigationController pushViewController:vc animated:YES];
                                }]];
    backgroundSection.footerTitle
        = NSLocalizedString(@"The information shown in notifications when your phone is locked.", @"");
    [contents addSection:backgroundSection];

    self.contents = contents;
}

#pragma mark - Events

- (void)didToggleSoundNotificationsSwitch:(UISwitch *)sender
{
    [Environment.shared.preferences setSoundInForeground:sender.on];
}

- (void)didToggleAPNsSwitch:(UISwitch *)sender
{
    [NSUserDefaults.standardUserDefaults setBool:sender.on forKey:@"isUsingFullAPNs"];
    __unused AnyPromise *promise = [OWSSyncPushTokensJob runWithAccountManager:AppEnvironment.shared.accountManager preferences:Environment.shared.preferences];
}

@end
