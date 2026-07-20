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

import Darwin
import Foundation
import UIKit

enum LegacyKeyboardHostResolver {
    @MainActor
    static func resolve(from inputViewController: UIInputViewController) -> String? {
        guard let hostPID = inputViewController.parent?.value(forKey: "_hostPID") else {
            return nil
        }

        let defaultServiceSelector = NSSelectorFromString("defaultService")
        guard let serviceClass: AnyObject = NSClassFromString("PKService"),
              let serviceProtocol = serviceClass as? NSObjectProtocol,
              serviceProtocol.responds(to: defaultServiceSelector),
              let service = serviceProtocol.perform(defaultServiceSelector)?
                .takeUnretainedValue() as? NSObjectProtocol,
              let personalities = service.perform(
                NSSelectorFromString("personalities")
              )?.takeUnretainedValue(),
              let extensionBundleIdentifier = Bundle.main.bundleIdentifier,
              let extensionPersonalities = personalities.object(
                forKey: extensionBundleIdentifier
              ) as? AnyObject,
              let personality = extensionPersonalities.object(forKey: hostPID) as? AnyObject,
              let connection = personality.perform(
                NSSelectorFromString("connection")
              )?.takeUnretainedValue() as? NSObjectProtocol,
              let xpcConnection = connection.perform(
                NSSelectorFromString("_xpcConnection")
              )?.takeUnretainedValue() else {
            return nil
        }

        guard let handle = dlopen("/usr/lib/libc.dylib", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let symbol = dlsym(handle, "xpc_connection_copy_bundle_id") else {
            return nil
        }

        typealias CopyBundleIdentifier = @convention(c) (
            AnyObject
        ) -> UnsafePointer<CChar>?
        let copyBundleIdentifier = unsafeBitCast(
            symbol,
            to: CopyBundleIdentifier.self
        )

        guard let value = copyBundleIdentifier(xpcConnection) else {
            return nil
        }
        let bundleIdentifier = String(cString: value)
        return bundleIdentifier.isEmpty ? nil : bundleIdentifier
    }
}
