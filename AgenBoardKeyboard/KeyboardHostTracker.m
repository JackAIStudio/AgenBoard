/*
 Adapted from KeyboardHostBundleID:
 https://github.com/editorss/KeyboardHostBundleID

 MIT License

 Copyright (c) 2026 editorss

 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:

 The above copyright notice and this permission notice shall be included in all
 copies or substantial portions of the Software.

 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 SOFTWARE.
 */

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const ABArbiterClientClassName =
    @"_UIKeyboardArbiterClient";
static NSString *const ABInputDestinationClassName =
    @"_UIKeyboardArbiterClientInputDestination";
static NSString *const ABKeyboardChangedSelectorName =
    @"queue_keyboardChanged:onComplete:";
static NSString *const ABSourceBundleIdentifierKey =
    @"_sourceBundleIdentifier";
static NSString *const ABAppGroupIdentifier =
    @"group.dev.local.agenboard";
static NSString *const ABStoredHostBundleIdentifierKey =
    @"keyboardHostBundleIdentifier";
static NSString *const ABStoredHostCapturedAtKey =
    @"keyboardHostBundleIdentifierCapturedAt";

static IMP ABOriginalKeyboardChangedImplementation = NULL;
static BOOL ABHostTrackingInstalled = NO;

static void ABStoreDiagnostic(NSString *key, id value) {
    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:ABAppGroupIdentifier];
    [defaults setObject:value forKey:key];
}

static BOOL ABIsUsableHostBundleIdentifier(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0 ||
        ![bundleIdentifier containsString:@"."]) {
        return NO;
    }

    NSString *extensionBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    if ([bundleIdentifier isEqualToString:extensionBundleIdentifier] ||
        [bundleIdentifier hasPrefix:@"dev.local.agenboard"]) {
        return NO;
    }

    return YES;
}

static void ABStoreHostBundleIdentifier(NSString *bundleIdentifier) {
    if (!ABIsUsableHostBundleIdentifier(bundleIdentifier)) {
        return;
    }

    NSUserDefaults *defaults =
        [[NSUserDefaults alloc] initWithSuiteName:ABAppGroupIdentifier];
    [defaults setObject:bundleIdentifier
                 forKey:ABStoredHostBundleIdentifierKey];
    [defaults setDouble:NSDate.date.timeIntervalSince1970
                 forKey:ABStoredHostCapturedAtKey];
    [defaults synchronize];
    NSLog(@"[AgenBoardHost] Captured host: %@", bundleIdentifier);
}

static void ABKeyboardChanged(
    id self,
    SEL selector,
    id change,
    id completion
) {
    ABStoreDiagnostic(
        @"keyboardHostTrackerLastCallbackAt",
        @(NSDate.date.timeIntervalSince1970)
    );

    if (change != nil) {
        @try {
            id value = [change valueForKey:ABSourceBundleIdentifierKey];
            ABStoreDiagnostic(
                @"keyboardHostTrackerLastValueClass",
                value == nil ? @"nil" : NSStringFromClass([value class])
            );
            if ([value isKindOfClass:NSString.class]) {
                ABStoreHostBundleIdentifier((NSString *)value);
            }
        } @catch (NSException *exception) {
            ABStoreDiagnostic(
                @"keyboardHostTrackerLastError",
                exception.reason ?: @"KVC exception"
            );
        }
    }

    if (ABOriginalKeyboardChangedImplementation != NULL) {
        ((void (*)(id, SEL, id, id))ABOriginalKeyboardChangedImplementation)(
            self,
            selector,
            change,
            completion
        );
    }
}

static BOOL ABKeyboardArbiterAlwaysEnabled(
    __unused id self,
    __unused SEL selector
) {
    return YES;
}

@interface KeyboardHostTracker : NSObject
@end

@implementation KeyboardHostTracker

+ (void)load {
    if (@available(iOS 26.4, *)) {
        ABStoreDiagnostic(
            @"keyboardHostTrackerLoadedAt",
            @(NSDate.date.timeIntervalSince1970)
        );
        [self installHostTracking];
    }
}

+ (void)installHostTracking {
    if (ABHostTrackingInstalled) {
        return;
    }

    Class arbiterClass = NSClassFromString(ABArbiterClientClassName);
    SEL enabledSelector = NSSelectorFromString(@"enabled");
    Method enabledMethod = class_getClassMethod(
        arbiterClass,
        enabledSelector
    );
    ABStoreDiagnostic(
        @"keyboardHostTrackerArbiterClassFound",
        @(arbiterClass != Nil)
    );
    ABStoreDiagnostic(
        @"keyboardHostTrackerEnabledMethodFound",
        @(enabledMethod != NULL)
    );
    if (enabledMethod != NULL) {
        method_setImplementation(
            enabledMethod,
            (IMP)ABKeyboardArbiterAlwaysEnabled
        );
    }

    Class destinationClass = NSClassFromString(
        ABInputDestinationClassName
    );
    SEL changedSelector = NSSelectorFromString(
        ABKeyboardChangedSelectorName
    );
    Method changedMethod = class_getInstanceMethod(
        destinationClass,
        changedSelector
    );
    ABStoreDiagnostic(
        @"keyboardHostTrackerDestinationClassFound",
        @(destinationClass != Nil)
    );
    ABStoreDiagnostic(
        @"keyboardHostTrackerChangedMethodFound",
        @(changedMethod != NULL)
    );
    if (changedMethod == NULL) {
        ABStoreDiagnostic(
            @"keyboardHostTrackerInstallStatus",
            @"keyboard change method unavailable"
        );
        return;
    }

    IMP currentImplementation = method_getImplementation(changedMethod);
    if (currentImplementation != (IMP)ABKeyboardChanged) {
        ABOriginalKeyboardChangedImplementation = currentImplementation;
        method_setImplementation(
            changedMethod,
            (IMP)ABKeyboardChanged
        );
    }
    ABHostTrackingInstalled = YES;
    ABStoreDiagnostic(@"keyboardHostTrackerInstallStatus", @"installed");
}

+ (void)refreshHostBundleIdentifier {
    [self installHostTracking];

    Class arbiterClass = NSClassFromString(ABArbiterClientClassName);
    SEL sharedSelector = NSSelectorFromString(
        @"automaticSharedArbiterClient"
    );

    if (arbiterClass == Nil ||
        ![arbiterClass respondsToSelector:sharedSelector]) {
        ABStoreDiagnostic(
            @"keyboardHostTrackerRefreshStatus",
            @"shared arbiter unavailable"
        );
        return;
    }

    id (*sendObject)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    id arbiter = sendObject(arbiterClass, sharedSelector);
    if (arbiter == nil) {
        ABStoreDiagnostic(
            @"keyboardHostTrackerRefreshStatus",
            @"shared arbiter is nil"
        );
        return;
    }

    SEL checkSelector = NSSelectorFromString(@"checkConnection");
    if (![arbiter respondsToSelector:checkSelector]) {
        ABStoreDiagnostic(
            @"keyboardHostTrackerRefreshStatus",
            @"checkConnection unavailable"
        );
        return;
    }

    void (*sendVoid)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
    sendVoid(arbiter, checkSelector);
    ABStoreDiagnostic(
        @"keyboardHostTrackerRefreshStatus",
        @"checkConnection sent"
    );
}

@end
