////////////////////////////////////////////////////////////////////////////
//
// Copyright 2014 Realm Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
////////////////////////////////////////////////////////////////////////////

import Foundation
import Realm
import Realm.Private
import Realm.Dynamic
import RealmSwift
import XCTest

func inMemoryRealm(inMememoryIdentifier: String) -> Realm {
    return try! Realm(configuration: Realm.Configuration(inMemoryIdentifier: inMememoryIdentifier))
}

class TestCase: XCTestCase {
    var exceptionThrown = false
    var testDir: String! = nil

    func realmWithTestPath(var configuration: Realm.Configuration = Realm.Configuration()) -> Realm {
        configuration.path = testRealmPath()
        return try! Realm(configuration: configuration)
    }

    override class func setUp() {
        super.setUp()
#if DEBUG || arch(i386) || arch(x86_64)
        // Disable actually syncing anything to the disk to greatly speed up the
        // tests, but only when not running on device because it can't be
        // re-enabled and we need it enabled for performance tests
        RLMDisableSyncToDisk()
#endif
    }

    override func invokeTest() {
        testDir = RLMRealmPathForFile(realmFilePrefix())

        do {
            try NSFileManager.defaultManager().removeItemAtPath(testDir)
        } catch {
            // The directory shouldn't actually already exist, so not an error
        }
        try! NSFileManager.defaultManager().createDirectoryAtPath(testDir, withIntermediateDirectories: true, attributes: nil)

        Realm.Configuration.defaultConfiguration = Realm.Configuration(path: defaultRealmPath())

        exceptionThrown = false
        autoreleasepool { super.invokeTest() }

        if exceptionThrown {
            RLMDeallocateRealm(defaultRealmPath())
            RLMDeallocateRealm(testRealmPath())
        }
        else {
            XCTAssertNil(RLMGetThreadLocalCachedRealmForPath(defaultRealmPath()))
            XCTAssertNil(RLMGetThreadLocalCachedRealmForPath(testRealmPath()))
        }

        do {
            try NSFileManager.defaultManager().removeItemAtPath(testDir)
        } catch {
            XCTFail("Unable to delete realm files")
        }
        RLMRealm.resetRealmState()
    }

    func dispatchSyncNewThread(block: dispatch_block_t) {
        let queue = dispatch_queue_create("background", nil)
        dispatch_async(queue) {
            autoreleasepool {
                block()
            }
        }
        dispatch_sync(queue) {}
    }

    func assertThrows<T>(@autoclosure(escaping) block: () -> T, _ message: String? = nil, named: String? = RLMExceptionName, fileName: String = __FILE__, lineNumber: UInt = __LINE__) {
        exceptionThrown = true
        RLMAssertThrows(self, { _ = block() } as dispatch_block_t, named, message, fileName, lineNumber)
    }

    func assertNil<T>(@autoclosure block: () -> T?, _ message: String? = nil, fileName: String = __FILE__, lineNumber: UInt = __LINE__) {
        XCTAssert(block() == nil, message ?? "", file: fileName, line: lineNumber)
    }

    private func realmFilePrefix() -> String {
        let remove = NSCharacterSet(charactersInString: "-[]")
        return self.name.stringByTrimmingCharactersInSet(remove)
    }

    internal func testRealmPath() -> String {
        return realmPathForFile("test.realm")
    }

    internal func defaultRealmPath() -> String {
        return realmPathForFile("default.realm")
    }

    private func realmPathForFile(fileName: String) -> String {
        return (testDir as NSString).stringByAppendingPathComponent(fileName)
    }
}
