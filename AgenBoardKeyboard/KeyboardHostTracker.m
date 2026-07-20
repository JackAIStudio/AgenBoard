/*
 Adapted from KeyboardHostBundleID:
 https://github.com/Muskupecli/KeyboardHostBundleID

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

static NSString *const ABArbiterClientClassName = @"_UIKeyboardArbiterClient";
static NSString *const ABInputDestinationClassName =
    @"_UIKeyboardArbiterClientInputDestination";
static NSString *const ABKeyboardChangedSelectorName =
    @"queue_keyboardChanged:onComplete:";
static NSString *const ABSourceBundleIdentifierKey = @"_sourceBundleIdentifier";
static NSString *const ABStoredHostBundleIdentifierKey =
    @"keyboardHostBundleIdentifier";
static NSString *const ABStoredHostCapturedAtKey =
    @"keyboardHostBundleIdentifierCapturedAt";
static NSString *const ABStoredHostGenerationKey = @"keyboardHostCaptureGeneration";

static IMP ABOriginalKeyboardChangedImplementation = NULL;
static BOOL ABHostTrackingInstalled = NO;

static NSString *ABConfiguredIdentifier(NSString *key, NSString *fallback) {
    id value = NSBundle.mainBundle.infoDictionary[key];
    if (![value isKindOfClass:NSString.class]) {
        return fallback;
    }

    NSString *identifier = [(NSString *)value
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (identifier.length == 0 || [identifier containsString:@"$("]) {
        return fallback;
    }
    return identifier;
}

static NSString *ABAppGroupIdentifier(void) {
    return ABConfiguredIdentifier(
        @"AgenBoardAppGroupIdentifier",
        @"group.dev.local.agenboard"
    );
}

static NSString *ABAppBundleIdentifier(void) {
    return ABConfiguredIdentifier(
        @"AgenBoardAppBundleIdentifier",
        @"dev.local.agenboard"
    );
}

static NSUserDefaults *ABSharedDefaults(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:ABAppGroupIdentifier()];
}

static void ABStoreDiagnostic(NSString *key, id value) {
    NSUserDefaults *defaults = ABSharedDefaults();
    [defaults setObject:value forKey:key];
    [defaults synchronize];
}

static BOOL ABIsUsableHostBundleIdentifier(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0 ||
        ![bundleIdentifier containsString:@"."]) {
        return NO;
    }

    NSString *extensionIdentifier = NSBundle.mainBundle.bundleIdentifier;
    return ![bundleIdentifier isEqualToString:extensionIdentifier] &&
        ![bundleIdentifier isEqualToString:ABAppBundleIdentifier()];
}

static void ABStoreHostBundleIdentifier(NSString *bundleIdentifier) {
    if (!ABIsUsableHostBundleIdentifier(bundleIdentifier)) {
        return;
    }

    NSUserDefaults *defaults = ABSharedDefaults();
    // The callback is the authoritative capture event. Give every callback its
    // own ID so Swift can consume a fresh event without first publishing a
    // generation (which is too late when +load receives the first callback).
    NSString *generation = NSUUID.UUID.UUIDString;
    NSTimeInterval capturedAt = NSDate.date.timeIntervalSince1970;
    [defaults setObject:bundleIdentifier forKey:ABStoredHostBundleIdentifierKey];
    [defaults setDouble:capturedAt forKey:ABStoredHostCapturedAtKey];
    [defaults setObject:generation forKey:ABStoredHostGenerationKey];
    [defaults setObject:bundleIdentifier forKey:@"keyboardHostTrackerLastBundleID"];
    [defaults setObject:generation
                 forKey:@"keyboardHostTrackerLastCaptureGeneration"];
    [defaults setDouble:capturedAt forKey:@"keyboardHostTrackerLastCallbackAt"];
    [defaults synchronize];
    NSLog(@"[AgenBoardHost] Captured host %@ generation %@",
          bundleIdentifier,
          generation);
}

static void ABKeyboardChanged(id self, SEL selector, id change, id completion) {
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
        [self installPassiveHostTracking];
    }
}

+ (void)installPassiveHostTracking {
    if (ABHostTrackingInstalled) {
        return;
    }

    // iOS 26.4+ gates destination-change delivery on this class method. It
    // must be enabled before UIKit's first arbiter dispatch; enabling it only
    // when the recording button is tapped is already too late.
    Class arbiterClass = NSClassFromString(ABArbiterClientClassName);
    Method enabledMethod = class_getClassMethod(
        arbiterClass,
        NSSelectorFromString(@"enabled")
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
        ABStoreDiagnostic(
            @"keyboardHostTrackerEnabledOverride",
            @"enabled for extension lifetime"
        );
    }

    Class destinationClass = NSClassFromString(ABInputDestinationClassName);
    Method changedMethod = class_getInstanceMethod(
        destinationClass,
        NSSelectorFromString(ABKeyboardChangedSelectorName)
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
        method_setImplementation(changedMethod, (IMP)ABKeyboardChanged);
    }
    ABHostTrackingInstalled = YES;
    ABStoreDiagnostic(
        @"keyboardHostTrackerInstallStatus",
        @"passive callback installed"
    );
}

+ (void)refreshHostBundleIdentifierOnce {
    [self installPassiveHostTracking];

    Class arbiterClass = NSClassFromString(ABArbiterClientClassName);
    SEL sharedSelector = NSSelectorFromString(@"automaticSharedArbiterClient");
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
    SEL checkSelector = NSSelectorFromString(@"checkConnection");
    if (arbiter == nil || ![arbiter respondsToSelector:checkSelector]) {
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
        @"single checkConnection sent"
    );
}

@end
