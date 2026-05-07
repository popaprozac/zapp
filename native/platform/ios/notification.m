// iOS notifications — UNUserNotificationCenter. Identical API to macOS,
// the only platform-specific bits are UIKit vs Cocoa import + the
// foreground-presentation availability check (Banner is iOS 14+, our
// minimum is iOS 15.0).

#import <UserNotifications/UserNotifications.h>
#import <UIKit/UIKit.h>
#import "../darwin/notification.h"

static char notif_result[2048];

// --- Notification delegate (handles clicks + action buttons) ---

extern void darwin_webview_eval_all(const char* js);

// Buffer for notification responses received before WebView is ready
static NSMutableArray<NSString*>* zapp_pending_notif_events = nil;
static BOOL zapp_notif_bridge_ready = NO;

void darwin_notification_set_bridge_ready(void) {
    zapp_notif_bridge_ready = YES;
    if (zapp_pending_notif_events && zapp_pending_notif_events.count > 0) {
        for (NSString* js in zapp_pending_notif_events) {
            darwin_webview_eval_all([js UTF8String]);
        }
        [zapp_pending_notif_events removeAllObjects];
    }
}

static void dispatch_notif_event(NSString* js) {
    if (zapp_notif_bridge_ready) {
        darwin_webview_eval_all([js UTF8String]);
    } else {
        if (!zapp_pending_notif_events) {
            zapp_pending_notif_events = [NSMutableArray new];
        }
        [zapp_pending_notif_events addObject:js];
    }
}

@interface ZappIOSNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@end

@implementation ZappIOSNotificationDelegate
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       didReceiveNotificationResponse:(UNNotificationResponse*)response
       withCompletionHandler:(void (^)(void))handler {
    (void)center;
    NSString* notifId = response.notification.request.identifier;
    NSString* actionId = response.actionIdentifier;

    NSString* eventName;
    NSString* payload;
    int appEventId;
    if ([actionId isEqualToString:UNNotificationDefaultActionIdentifier]) {
        eventName = @"__notif:click";
        payload = [NSString stringWithFormat:@"{\"id\":\"%@\"}", notifId];
        appEventId = 102; // ZAPP_EVENT_APP_NOTIFICATION_CLICK
    } else if ([actionId isEqualToString:UNNotificationDismissActionIdentifier]) {
        handler();
        return;
    } else {
        eventName = @"__notif:action";
        NSString* escapedAction = [actionId stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];

        NSString* userText = @"";
        if ([response isKindOfClass:[UNTextInputNotificationResponse class]]) {
            userText = [(UNTextInputNotificationResponse*)response userText] ?: @"";
            userText = [userText stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
        }

        if (userText.length > 0) {
            payload = [NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"%@\",\"userText\":\"%@\"}",
                notifId, escapedAction, userText];
        } else {
            payload = [NSString stringWithFormat:@"{\"id\":\"%@\",\"action\":\"%@\"}", notifId, escapedAction];
        }
        appEventId = 103; // ZAPP_EVENT_APP_NOTIFICATION_ACTION
    }

    extern int zapp_app_dispatch(int event_id, const char* data);
    zapp_app_dispatch(appEventId, [payload UTF8String]);

    NSString* escapedName = [eventName stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString* escapedPayload = [payload stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
    NSString* js = [NSString stringWithFormat:
        @"(function(){var b=globalThis[Symbol.for('zapp.bridge')];"
        "if(b&&b._onEvent)b._onEvent('%@','%@');})();",
        escapedName, escapedPayload];
    dispatch_notif_event(js);

    handler();
}

// Show notifications even when app is in foreground. iOS 14+ has Banner;
// our minimum is 15.0 so we can use it unconditionally.
- (void)userNotificationCenter:(UNUserNotificationCenter*)center
       willPresentNotification:(UNNotification*)notification
       withCompletionHandler:(void (^)(UNNotificationPresentationOptions))handler {
    (void)center; (void)notification;
    handler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}
@end

static ZappIOSNotificationDelegate* zapp_notif_delegate = nil;

void darwin_notification_setup_delegate(void) {
    if (zapp_notif_delegate) return;
    zapp_notif_delegate = [[ZappIOSNotificationDelegate alloc] init];
    [[UNUserNotificationCenter currentNotificationCenter] setDelegate:zapp_notif_delegate];
}

// --- Permission ---

static const char* status_string(UNAuthorizationStatus status) {
    switch (status) {
        case UNAuthorizationStatusAuthorized: return "granted";
        case UNAuthorizationStatusDenied: return "denied";
        case UNAuthorizationStatusProvisional: return "provisional";
        default: return "not-determined";
    }
}

void darwin_notification_request_permission(int32_t window_id, int32_t request_id, notif_callback_fn cb) {
    darwin_notification_setup_delegate();

    [[UNUserNotificationCenter currentNotificationCenter]
        requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound | UNAuthorizationOptionBadge)
        completionHandler:^(BOOL granted, NSError* error) {
            (void)error;
            NSString* json = [NSString stringWithFormat:@"{\"status\":\"%@\"}", granted ? @"granted" : @"denied"];
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(window_id, request_id, true, [json UTF8String]);
            });
        }];
}

const char* darwin_notification_get_permission(void) {
    darwin_notification_setup_delegate();

    __block const char* result_status = "not-determined";
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[UNUserNotificationCenter currentNotificationCenter]
        getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings* settings) {
            result_status = status_string(settings.authorizationStatus);
            dispatch_semaphore_signal(sem);
        }];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
    snprintf(notif_result, sizeof(notif_result), "{\"status\":\"%s\"}", result_status);
    return notif_result;
}

// --- Show / Schedule ---

static NSDictionary* parse_notif_json(const char* json) {
    if (!json || json[0] == '\0') return @{};
    NSData* data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return @{};
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : @{};
}

static UNMutableNotificationContent* build_content(NSDictionary* opts) {
    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];

    NSString* title = opts[@"title"];
    if (title) content.title = title;

    NSString* subtitle = opts[@"subtitle"];
    if (subtitle) content.subtitle = subtitle;

    NSString* body = opts[@"body"];
    if (body) content.body = body;

    NSString* sound = opts[@"sound"];
    if (!sound || [sound isEqualToString:@"default"]) {
        content.sound = [UNNotificationSound defaultSound];
    } else if (![sound isEqualToString:@"none"]) {
        content.sound = [UNNotificationSound soundNamed:sound];
    }

    NSString* threadId = opts[@"threadId"];
    if (threadId) content.threadIdentifier = threadId;

    NSString* categoryId = opts[@"categoryId"];
    if (categoryId) content.categoryIdentifier = categoryId;

    return content;
}

void darwin_notification_show(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb) {
    darwin_notification_setup_delegate();
    NSDictionary* opts = parse_notif_json(options_json);
    UNMutableNotificationContent* content = build_content(opts);

    NSString* identifier = opts[@"id"];
    if (!identifier || [identifier length] == 0) {
        identifier = [[NSUUID UUID] UUIDString];
    }

    NSString* attachmentPath = opts[@"attachment"];
    if (attachmentPath && [attachmentPath length] > 0) {
        NSURL* url;
        if ([attachmentPath hasPrefix:@"file://"]) {
            url = [NSURL URLWithString:attachmentPath];
        } else {
            url = [NSURL fileURLWithPath:attachmentPath];
        }
        NSError* err = nil;
        UNNotificationAttachment* attachment =
            [UNNotificationAttachment attachmentWithIdentifier:@"" URL:url options:nil error:&err];
        if (attachment) content.attachments = @[attachment];
        else if (err) NSLog(@"[zapp] attachment error: %@", err);
    }

    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];

    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    NSString* idCopy = [identifier copy];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
        withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] notification error: %@", error);
            NSString* json = [NSString stringWithFormat:@"{\"id\":\"%@\"}", idCopy];
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(window_id, request_id, error == nil, [json UTF8String]);
            });
        }];
}

void darwin_notification_schedule(const char* options_json, int32_t window_id, int32_t request_id, notif_callback_fn cb) {
    darwin_notification_setup_delegate();
    NSDictionary* opts = parse_notif_json(options_json);
    UNMutableNotificationContent* content = build_content(opts);

    NSString* identifier = [[NSUUID UUID] UUIDString];

    NSDictionary* triggerOpts = opts[@"trigger"];
    UNNotificationTrigger* trigger = nil;

    NSNumber* seconds = triggerOpts[@"seconds"];
    if (seconds) {
        trigger = [UNTimeIntervalNotificationTrigger
            triggerWithTimeInterval:[seconds doubleValue] repeats:NO];
    } else {
        NSDateComponents* components = [[NSDateComponents alloc] init];
        NSNumber* year = triggerOpts[@"year"];
        if (year) components.year = [year integerValue];
        NSNumber* month = triggerOpts[@"month"];
        if (month) components.month = [month integerValue];
        NSNumber* day = triggerOpts[@"day"];
        if (day) components.day = [day integerValue];
        NSNumber* hour = triggerOpts[@"hour"];
        if (hour) components.hour = [hour integerValue];
        NSNumber* minute = triggerOpts[@"minute"];
        if (minute) components.minute = [minute integerValue];
        trigger = [UNCalendarNotificationTrigger
            triggerWithDateMatchingComponents:components repeats:NO];
    }

    if (!trigger) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(window_id, request_id, false, "{\"error\":\"invalid trigger\"}");
        });
        return;
    }

    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    NSString* idCopy = [identifier copy];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
        withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] schedule error: %@", error);
            NSString* json = [NSString stringWithFormat:@"{\"id\":\"%@\"}", idCopy];
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(window_id, request_id, error == nil, [json UTF8String]);
            });
        }];
}

// --- Cancel ---

void darwin_notification_cancel(const char* notification_id) {
    if (!notification_id) return;
    NSString* identifier = [NSString stringWithUTF8String:notification_id];
    [[UNUserNotificationCenter currentNotificationCenter]
        removePendingNotificationRequestsWithIdentifiers:@[identifier]];
}

void darwin_notification_cancel_all(void) {
    [[UNUserNotificationCenter currentNotificationCenter]
        removeAllPendingNotificationRequests];
}

// --- Categories ---

static NSMutableDictionary<NSString*, UNNotificationCategory*>* zapp_notif_categories = nil;

static void zapp_notif_sync_categories(void) {
    if (!zapp_notif_categories) return;
    NSSet* catSet = [NSSet setWithArray:[zapp_notif_categories allValues]];
    [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:catSet];
}

void darwin_notification_register_category_typed(
    const char* cat_id,
    ZappNotifAction* actions, int action_count,
    int has_reply, const char* reply_placeholder, const char* reply_button) {

    if (!cat_id) return;
    darwin_notification_setup_delegate();
    if (!zapp_notif_categories) zapp_notif_categories = [NSMutableDictionary new];

    NSString* catId = [NSString stringWithUTF8String:cat_id];
    NSMutableArray<UNNotificationAction*>* nsActions = [NSMutableArray new];

    for (int i = 0; i < action_count; i++) {
        if (!actions[i].id || !actions[i].title) continue;
        NSString* actionId = [NSString stringWithUTF8String:actions[i].id];
        NSString* actionTitle = [NSString stringWithUTF8String:actions[i].title];
        UNNotificationActionOptions opts = UNNotificationActionOptionForeground;
        if (actions[i].destructive) opts |= UNNotificationActionOptionDestructive;

        UNNotificationAction* action = [UNNotificationAction
            actionWithIdentifier:actionId title:actionTitle options:opts];
        [nsActions addObject:action];
    }

    if (has_reply) {
        NSString* placeholder = (reply_placeholder && reply_placeholder[0])
            ? [NSString stringWithUTF8String:reply_placeholder] : @"";
        NSString* buttonTitle = (reply_button && reply_button[0])
            ? [NSString stringWithUTF8String:reply_button] : @"Send";
        UNTextInputNotificationAction* replyAction = [UNTextInputNotificationAction
            actionWithIdentifier:@"__reply"
            title:buttonTitle
            options:UNNotificationActionOptionForeground
            textInputButtonTitle:buttonTitle
            textInputPlaceholder:placeholder];
        [nsActions addObject:replyAction];
    }

    UNNotificationCategory* category = [UNNotificationCategory
        categoryWithIdentifier:catId
        actions:nsActions
        intentIdentifiers:@[]
        options:UNNotificationCategoryOptionNone];

    zapp_notif_categories[catId] = category;
    zapp_notif_sync_categories();
}

void darwin_notification_register_category(const char* category_id, const char* actions_json) {
    if (!category_id) return;
    darwin_notification_setup_delegate();
    if (!zapp_notif_categories) zapp_notif_categories = [NSMutableDictionary new];

    NSString* catId = [NSString stringWithUTF8String:category_id];
    NSMutableArray<UNNotificationAction*>* actions = [NSMutableArray new];
    int has_reply = 0;
    NSString* reply_placeholder = @"";
    NSString* reply_button = @"Send";

    if (actions_json) {
        NSData* data = [[NSString stringWithUTF8String:actions_json] dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;

        NSArray* items = nil;
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            NSDictionary* catDict = (NSDictionary*)parsed;
            items = catDict[@"actions"];
            if ([catDict[@"hasReplyField"] boolValue]) has_reply = 1;
            if (catDict[@"replyPlaceholder"]) reply_placeholder = catDict[@"replyPlaceholder"];
            if (catDict[@"replyButtonTitle"]) reply_button = catDict[@"replyButtonTitle"];
        } else if ([parsed isKindOfClass:[NSArray class]]) {
            items = (NSArray*)parsed;
        }

        if ([items isKindOfClass:[NSArray class]]) {
            for (NSDictionary* item in items) {
                NSString* actionId = item[@"id"];
                NSString* actionTitle = item[@"title"];
                if (!actionId || !actionTitle) continue;
                UNNotificationActionOptions opts = UNNotificationActionOptionForeground;
                if ([item[@"destructive"] boolValue]) opts |= UNNotificationActionOptionDestructive;
                [actions addObject:[UNNotificationAction actionWithIdentifier:actionId title:actionTitle options:opts]];
            }
        }
    }

    if (has_reply) {
        [actions addObject:[UNTextInputNotificationAction
            actionWithIdentifier:@"__reply"
            title:reply_button
            options:UNNotificationActionOptionForeground
            textInputButtonTitle:reply_button
            textInputPlaceholder:reply_placeholder]];
    }

    UNNotificationCategory* category = [UNNotificationCategory
        categoryWithIdentifier:catId actions:actions intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];
    zapp_notif_categories[catId] = category;
    zapp_notif_sync_categories();
}

void darwin_notification_remove_category(const char* cat_id) {
    if (!cat_id || !zapp_notif_categories) return;
    NSString* catId = [NSString stringWithUTF8String:cat_id];
    [zapp_notif_categories removeObjectForKey:catId];
    zapp_notif_sync_categories();
}

void darwin_notification_show_with_category(const char* title, const char* body,
                                             const char* category_id) {
    darwin_notification_setup_delegate();

    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    if (title && title[0]) content.title = [NSString stringWithUTF8String:title];
    if (body && body[0]) content.body = [NSString stringWithUTF8String:body];
    content.sound = [UNNotificationSound defaultSound];
    if (category_id && category_id[0])
        content.categoryIdentifier = [NSString stringWithUTF8String:category_id];

    NSString* identifier = [[NSUUID UUID] UUIDString];
    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] notification error: %@", error);
        }];
}

// JSON wrappers for router.

void darwin_notification_remove_delivered_json(const char* json) {
    if (!json) return;
    NSDictionary* opts = parse_notif_json(json);
    NSString* nid = opts[@"id"];
    if (nid && nid.length > 0) {
        darwin_notification_remove_delivered([nid UTF8String]);
    }
}

void darwin_notification_update_json(const char* json) {
    if (!json) return;
    NSDictionary* opts = parse_notif_json(json);
    NSString* nid = opts[@"id"];
    if (!nid || nid.length == 0) return;
    darwin_notification_update(
        [nid UTF8String],
        [opts[@"title"] UTF8String] ?: "",
        [opts[@"subtitle"] UTF8String] ?: "",
        [opts[@"body"] UTF8String] ?: "");
}

void darwin_notification_show_typed(const char* title, const char* subtitle, const char* body, const char* sound) {
    darwin_notification_setup_delegate();

    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    if (title && title[0]) content.title = [NSString stringWithUTF8String:title];
    if (subtitle && subtitle[0]) content.subtitle = [NSString stringWithUTF8String:subtitle];
    if (body && body[0]) content.body = [NSString stringWithUTF8String:body];
    if (!sound || strcmp(sound, "default") == 0) {
        content.sound = [UNNotificationSound defaultSound];
    } else if (strcmp(sound, "none") != 0) {
        content.sound = [UNNotificationSound soundNamed:[NSString stringWithUTF8String:sound]];
    }

    NSString* identifier = [[NSUUID UUID] UUIDString];
    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] notification error: %@", error);
        }];
}

void darwin_notification_schedule_typed(const char* title, const char* body, double delay_seconds) {
    darwin_notification_setup_delegate();

    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    if (title && title[0]) content.title = [NSString stringWithUTF8String:title];
    if (body && body[0]) content.body = [NSString stringWithUTF8String:body];
    content.sound = [UNNotificationSound defaultSound];

    NSString* identifier = [[NSUUID UUID] UUIDString];
    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:delay_seconds repeats:NO];
    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] notification error: %@", error);
        }];
}

// --- Extended notification features ---

void darwin_notification_remove_delivered(const char* notification_id) {
    if (!notification_id) return;
    NSString* nid = [NSString stringWithUTF8String:notification_id];
    [[UNUserNotificationCenter currentNotificationCenter]
        removeDeliveredNotificationsWithIdentifiers:@[nid]];
}

void darwin_notification_remove_all_delivered(void) {
    [[UNUserNotificationCenter currentNotificationCenter] removeAllDeliveredNotifications];
}

void darwin_notification_update(const char* notification_id, const char* title,
                                const char* subtitle, const char* body) {
    if (!notification_id) return;
    darwin_notification_setup_delegate();

    UNMutableNotificationContent* content = [[UNMutableNotificationContent alloc] init];
    if (title && title[0]) content.title = [NSString stringWithUTF8String:title];
    if (subtitle && subtitle[0]) content.subtitle = [NSString stringWithUTF8String:subtitle];
    if (body && body[0]) content.body = [NSString stringWithUTF8String:body];
    content.sound = [UNNotificationSound defaultSound];

    NSString* identifier = [NSString stringWithUTF8String:notification_id];
    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] notification update error: %@", error);
        }];
}

void darwin_notification_show_with_attachment(const char* options_json,
    const char* attachment_url, int32_t window_id, int32_t request_id, notif_callback_fn cb) {

    darwin_notification_setup_delegate();
    NSDictionary* opts = parse_notif_json(options_json);
    UNMutableNotificationContent* content = build_content(opts);

    if (attachment_url && attachment_url[0]) {
        NSString* urlStr = [NSString stringWithUTF8String:attachment_url];
        NSURL* url;
        if ([urlStr hasPrefix:@"file://"]) {
            url = [NSURL URLWithString:urlStr];
        } else {
            url = [NSURL fileURLWithPath:urlStr];
        }

        NSError* attachError = nil;
        UNNotificationAttachment* attachment =
            [UNNotificationAttachment attachmentWithIdentifier:@""
                URL:url options:nil error:&attachError];
        if (attachment) {
            content.attachments = @[attachment];
        } else if (attachError) {
            NSLog(@"[zapp] attachment error: %@", attachError);
        }
    }

    NSString* identifier = [[NSUUID UUID] UUIDString];
    UNTimeIntervalNotificationTrigger* trigger =
        [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
    UNNotificationRequest* request =
        [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];

    NSString* idCopy = [identifier copy];
    [[UNUserNotificationCenter currentNotificationCenter]
        addNotificationRequest:request
        withCompletionHandler:^(NSError* error) {
            if (error) NSLog(@"[zapp] notification error: %@", error);
            NSString* json = [NSString stringWithFormat:@"{\"id\":\"%@\"}", idCopy];
            dispatch_async(dispatch_get_main_queue(), ^{
                cb(window_id, request_id, error == nil, [json UTF8String]);
            });
        }];
}
