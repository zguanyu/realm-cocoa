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

#import "RLMRealm_Private.hpp"

#import "RLMAnalytics.hpp"
#import "RLMArray_Private.hpp"
#import "RLMRealmConfiguration_Private.h"
#import "RLMMigration_Private.h"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.h"
#import "RLMObject_Private.hpp"
#import "RLMObservation.hpp"
#import "RLMProperty.h"
#import "RLMQueryUtil.hpp"
#import "RLMRealmUtil.h"
#import "RLMSchema_Private.h"
#import "RLMUpdateChecker.hpp"
#import "RLMUtil.hpp"

#include "object_store.hpp"
#include <realm/commit_log.hpp>
#include <realm/disable_sync_to_disk.hpp>
#include <realm/group_shared.hpp>
#include <realm/lang_bind_helper.hpp>
#include <realm/version.hpp>

using namespace realm;
using util::File;

void RLMDisableSyncToDisk() {
    realm::disable_sync_to_disk();
}

// Notification Token

@interface RLMNotificationToken ()
@property (nonatomic, strong) RLMRealm *realm;
@property (nonatomic, copy) RLMNotificationBlock block;
@end

@implementation RLMNotificationToken
- (void)dealloc
{
    if (_realm || _block) {
        NSLog(@"RLMNotificationToken released without unregistering a notification. You must hold "
              @"on to the RLMNotificationToken returned from addNotificationBlock and call "
              @"removeNotification: when you no longer wish to recieve RLMRealm notifications.");
    }
}
@end

static bool shouldForciblyDisableEncryption()
{
    static bool disableEncryption = getenv("REALM_DISABLE_ENCRYPTION");
    return disableEncryption;
}

NSData *RLMRealmValidatedEncryptionKey(NSData *key) {
    if (shouldForciblyDisableEncryption()) {
        return nil;
    }

    if (key) {
        if (key.length != 64) {
            @throw RLMException(@"Encryption key must be exactly 64 bytes long");
        }
        if (RLMIsDebuggerAttached()) {
            @throw RLMException(@"Cannot open an encrypted Realm with a debugger attached to the process");
        }
#if TARGET_OS_WATCH
        @throw RLMException(@"Cannot open an encrypted Realm on watchOS.");
#endif
    }

    return key;
}

@implementation RLMRealm {
    // Used for read-write realms
    NSHashTable *_notificationHandlers;
    NSHashTable *_collectionEnumerators;

    std::unique_ptr<ClientHistory> _history;
    std::unique_ptr<SharedGroup> _sharedGroup;

    // Used for read-only realms
    std::unique_ptr<Group> _readGroup;

    // Used for both
    Group *_group;
    BOOL _readOnly;
    BOOL _inMemory;

    NSData *_encryptionKey;
}

- (BOOL)isEmpty
{
    return realm::ObjectStore::is_empty(self.group);
}

+ (BOOL)isCoreDebug {
    return realm::Version::has_feature(realm::feature_Debug);
}

+ (void)initialize {
    static bool initialized;
    if (initialized) {
        return;
    }
    initialized = true;

    RLMCheckForUpdates();
    RLMInstallUncaughtExceptionHandler();
    RLMSendAnalytics();
}

- (instancetype)initWithPath:(NSString *)path key:(NSData *)key readOnly:(BOOL)readonly inMemory:(BOOL)inMemory dynamic:(BOOL)dynamic error:(NSError **)outError {
    self = [super init];
    if (self) {
        _path = path;
        _threadID = pthread_mach_thread_np(pthread_self());
        _notificationHandlers = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
        _readOnly = readonly;
        _inMemory = inMemory;
        _dynamic = dynamic;
        _encryptionKey = key;
        _autorefresh = YES;

        NSError *error = nil;
        try {
            if (readonly) {
                _readGroup = std::make_unique<Group>(path.UTF8String, static_cast<const char *>(key.bytes));
                _group = _readGroup.get();
            }
            else {
                _history = realm::make_client_history(path.UTF8String,
                                                      static_cast<const char *>(key.bytes));
                SharedGroup::DurabilityLevel durability = inMemory ? SharedGroup::durability_MemOnly :
                                                                     SharedGroup::durability_Full;
                _sharedGroup = std::make_unique<SharedGroup>(*_history, durability,
                                                             static_cast<const char *>(key.bytes));
            }
        }
        catch (File::PermissionDenied const& ex) {
            NSString *mode = readonly ? @"read" : @"read-write";
            NSString *additionalMessage = [NSString stringWithFormat:@"Unable to open a realm at path '%@'. Please use a path where your app has %@ permissions.", path, mode];
            NSString *newMessage = [NSString stringWithFormat:@"%s\n%@", ex.what(), additionalMessage];
            error = RLMMakeError(RLMErrorFilePermissionDenied, File::PermissionDenied(newMessage.UTF8String, ex.get_path()));
        }
        catch (File::Exists const& ex) {
            error = RLMMakeError(RLMErrorFileExists, ex);
        }
        catch (File::AccessError const& ex) {
            error = RLMMakeError(RLMErrorFileAccessError, ex);
        }
        catch (IncompatibleLockFile const&) {
            NSString *err = @"Realm file is currently open in another process "
                             "which cannot share access with this process. All "
                             "processes sharing a single file must be the same "
                             "architecture. For sharing files between the Realm "
                             "Browser and an iOS simulator, this means that you "
                             "must use a 64-bit simulator.";
            error = [NSError errorWithDomain:RLMErrorDomain
                                        code:RLMErrorIncompatibleLockFile
                                    userInfo:@{NSLocalizedDescriptionKey: err,
                                               @"Error Code": @(RLMErrorIncompatibleLockFile)}];
        }
        catch (std::exception const& ex) {
            error = RLMMakeError(RLMErrorFail, ex);
        }

        if (error) {
            RLMSetErrorOrThrow(error, outError);
            return nil;
        }

    }
    return self;
}

- (realm::Group *)getOrCreateGroup {
    if (!_group) {
        _group = &const_cast<Group&>(_sharedGroup->begin_read());
    }
    return _group;
}

+ (NSString *)writeableTemporaryPathForFile:(NSString *)fileName {
    return [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
}

+ (instancetype)defaultRealm
{
    return [RLMRealm realmWithConfiguration:[RLMRealmConfiguration rawDefaultConfiguration] error:nil];
}

+ (instancetype)realmWithPath:(NSString *)path
{
    // FIXME: this is a breaking change
    RLMRealmConfiguration *configuration = [RLMRealmConfiguration defaultConfiguration];
    configuration.path = path;
    return [RLMRealm realmWithConfiguration:configuration error:nil];
}

+ (instancetype)realmWithPath:(NSString *)path
                          key:(NSData *)key
                     readOnly:(BOOL)readonly
                     inMemory:(BOOL)inMemory
                      dynamic:(BOOL)dynamic
                       schema:(RLMSchema *)customSchema
                        error:(NSError **)outError
{
    RLMRealmConfiguration *configuration = [[RLMRealmConfiguration alloc] init];
    if (inMemory) {
        configuration.inMemoryIdentifier = path.lastPathComponent;
    }
    else {
        configuration.path = path;
    }
    configuration.encryptionKey = key;
    configuration.readOnly = readonly;
    configuration.dynamic = dynamic;
    configuration.customSchema = customSchema;
    return [RLMRealm realmWithConfiguration:configuration error:outError];
}

// ARC tries to eliminate calls to autorelease when the value is then immediately
// returned, but this results in significantly different semantics between debug
// and release builds for RLMRealm, so force it to always autorelease.
static id RLMAutorelease(id value) {
    // +1 __bridge_retained, -1 CFAutorelease
    return value ? (__bridge id)CFAutorelease((__bridge_retained CFTypeRef)value) : nil;
}

+ (instancetype)realmWithConfiguration:(RLMRealmConfiguration *)configuration error:(NSError **)error {
    NSString *path = configuration.path;
    bool inMemory = false;
    if (configuration.inMemoryIdentifier) {
        inMemory = true;
        path = [RLMRealm writeableTemporaryPathForFile:configuration.inMemoryIdentifier];
    }
    RLMSchema *customSchema = configuration.customSchema;
    bool dynamic = configuration.dynamic;
    bool readOnly = configuration.readOnly;

    // try to reuse existing realm first
    RLMRealm *realm = RLMGetThreadLocalCachedRealmForPath(path);
    if (realm) {
        if (realm->_readOnly != readOnly) {
            @throw RLMException(@"Realm at path already opened with different read permissions", @{@"path":realm.path});
        }
        if (realm->_inMemory != inMemory) {
            @throw RLMException(@"Realm at path already opened with different inMemory settings", @{@"path":realm.path});
        }
        if (realm->_dynamic != dynamic) {
            @throw RLMException(@"Realm at path already opened with different dynamic settings", @{@"path":realm.path});
        }
        return RLMAutorelease(realm);
    }

    NSData *key = configuration.encryptionKey;
    realm = [[RLMRealm alloc] initWithPath:path key:key readOnly:readOnly inMemory:inMemory dynamic:dynamic error:error];
    if (error && *error) {
        return nil;
    }

    // we need to protect the realm cache and accessors cache
    static id initLock = [NSObject new];
    @synchronized(initLock) {
        // create tables, set schema, and create accessors when needed
        if (readOnly || (dynamic && !customSchema)) {
            // for readonly realms and dynamic realms without a custom schema just set the schema
            if (realm::ObjectStore::get_schema_version(realm.group) == realm::ObjectStore::NotVersioned) {
                RLMSetErrorOrThrow([NSError errorWithDomain:RLMErrorDomain code:RLMErrorFail userInfo:@{NSLocalizedDescriptionKey:@"Cannot open an uninitialized realm in read-only mode"}], error);
                return nil;
            }
            RLMSchema *targetSchema = readOnly ? [RLMSchema.sharedSchema copy] : [RLMSchema dynamicSchemaFromRealm:realm];
            RLMRealmSetSchema(realm, targetSchema, true);
            RLMRealmCreateAccessors(realm.schema);
        }
        else {
            // check cache for existing cached realms with the same path
            RLMRealm *existingRealm = RLMGetAnyCachedRealmForPath(path);
            if (existingRealm) {
                // if we have a cached realm on another thread, copy without a transaction
                RLMRealmSetSchema(realm, [existingRealm.schema shallowCopy], false);
            }
            else {
                // if we are the first realm at this path, set/align schema or perform migration if needed
                RLMSchema *targetSchema = customSchema ?: RLMSchema.sharedSchema;
                @try {
                    RLMUpdateRealmToSchemaVersion(realm, configuration.schemaVersion, [targetSchema copy], [realm migrationBlock:configuration.migrationBlock key:key]);
                }
                @catch (NSException *exception) {
                    RLMSetErrorOrThrow(RLMMakeError(exception), error);
                    return nil;
                }

                RLMRealmCreateAccessors(realm.schema);
            }

            // initializing the schema started a read transaction, so end it
            [realm invalidate];
        }

        if (!dynamic) {
            RLMCacheRealm(realm);
        }
    }

    if (!readOnly) {
        realm.notifier = [[RLMNotifier alloc] initWithRealm:realm error:error];
        if (!realm.notifier) {
            return nil;
        }
    }

    return RLMAutorelease(realm);
}

- (NSError *(^)())migrationBlock:(RLMMigrationBlock)userBlock key:(NSData *)encryptionKey {
    if (userBlock) {
        return ^{
            NSError *error;
            RLMMigration *migration = [[RLMMigration alloc] initWithRealm:self key:encryptionKey error:&error];
            if (error) {
                return error;
            }

            [migration execute:userBlock];
            return error;
        };
    }
    return nil;
}

+ (void)resetRealmState {
    RLMClearRealmCache();
    [RLMRealmConfiguration resetRealmConfigurationState];
}

static void CheckReadWrite(RLMRealm *realm, NSString *msg=@"Cannot write to a read-only Realm") {
    if (realm->_readOnly) {
        @throw RLMException(msg);
    }
}

- (RLMNotificationToken *)addNotificationBlock:(RLMNotificationBlock)block {
    RLMCheckThread(self);
    CheckReadWrite(self, @"Read-only Realms do not change and do not have change notifications");
    if (!block) {
        @throw RLMException(@"The notification block should not be nil");
    }

    RLMNotificationToken *token = [[RLMNotificationToken alloc] init];
    token.realm = self;
    token.block = block;
    [_notificationHandlers addObject:token];
    return token;
}

- (void)removeNotification:(RLMNotificationToken *)token {
    RLMCheckThread(self);
    if (token) {
        [_notificationHandlers removeObject:token];
        token.realm = nil;
        token.block = nil;
    }
}

- (void)sendNotifications:(NSString *)notification {
    NSAssert(!_readOnly, @"Read-only realms do not have notifications");

    // call this realms notification blocks
    for (RLMNotificationToken *token in [_notificationHandlers allObjects]) {
        if (token.block) {
            token.block(notification, self);
        }
    }
}

- (RLMRealmConfiguration *)configuration {
    RLMRealmConfiguration *configuration = [[RLMRealmConfiguration alloc] init];
    configuration.path = self.path;
    configuration.schemaVersion = realm::ObjectStore::get_schema_version(self.group);
    if (_inMemory) {
        configuration.inMemoryIdentifier = [_path lastPathComponent];
    }
    configuration.readOnly = _readOnly;
    configuration.encryptionKey = _encryptionKey;
    configuration.dynamic = _dynamic;
    configuration.customSchema = _schema;
    return configuration;
}

- (void)beginWriteTransaction {
    CheckReadWrite(self);
    RLMCheckThread(self);

    if (!self.inWriteTransaction) {
        try {
            // if the upgrade to write will move the transaction forward,
            // announce the change after promoting
            bool announce = _sharedGroup->has_changed();

            // begin the read transaction if needed
            [self getOrCreateGroup];

            // notify any collections currently being enumerated that they need
            // to switch to enumerating a copy as the data may change on them
            for (RLMFastEnumerator *enumerator in _collectionEnumerators) {
                [enumerator detach];
            }
            _collectionEnumerators = nil;

            RLMPromoteToWrite(*_sharedGroup, *_history, _schema);

            // update state and make all objects in this realm writable
            _inWriteTransaction = YES;

            if (announce) {
                [self sendNotifications:RLMRealmDidChangeNotification];
            }
        }
        catch (std::exception& ex) {
            // File access errors are treated as exceptions here since they should not occur after the shared
            // group has already been successfully opened on the file and memory mapped. The shared group constructor handles
            // the excepted error related to file access.
            @throw RLMException(ex);
        }
    } else {
        @throw RLMException(@"The Realm is already in a write transaction");
    }
}

- (void)commitWriteTransaction {
    [self commitWriteTransaction:nil];
}

- (BOOL)commitWriteTransaction:(NSError **)outError {
    CheckReadWrite(self);
    RLMCheckThread(self);

    if (self.inWriteTransaction) {
        try {
            LangBindHelper::commit_and_continue_as_read(*_sharedGroup);

            // update state and make all objects in this realm read-only
            _inWriteTransaction = NO;

            // notify other realm instances of changes
            [self.notifier notifyOtherRealms];
        }
        catch (std::exception& ex) {
            RLMSetErrorOrThrow(RLMMakeError(RLMErrorFail, ex), outError);
            return NO;
        }
        // send local notification
        [self sendNotifications:RLMRealmDidChangeNotification];
    } else {
        @throw RLMException(@"Can't commit a non-existing write transaction");
    }
    return YES;
}

- (void)transactionWithBlock:(void(^)(void))block {
    [self transactionWithBlock:block error:nil];
}

- (BOOL)transactionWithBlock:(void(^)(void))block error:(NSError **)outError {
    [self beginWriteTransaction];
    block();
    if (_inWriteTransaction) {
        return [self commitWriteTransaction:outError];
    }
    return YES;
}

- (void)cancelWriteTransaction {
    CheckReadWrite(self);
    RLMCheckThread(self);

    if (self.inWriteTransaction) {
        try {
            RLMRollbackAndContinueAsRead(*_sharedGroup, *_history, _schema);
            _inWriteTransaction = NO;
        }
        catch (std::exception& ex) {
            @throw RLMException(ex);
        }
    } else {
        @throw RLMException(@"Can't cancel a non-existing write transaction");
    }
}

- (void)invalidate {
    RLMCheckThread(self);
    CheckReadWrite(self, @"Cannot invalidate a read-only realm");

    if (_inWriteTransaction) {
        NSLog(@"WARNING: An RLMRealm instance was invalidated during a write "
              "transaction and all pending changes have been rolled back.");
        [self cancelWriteTransaction];
    }
    if (!_group) {
        // Nothing to do if the read transaction hasn't been begun
        return;
    }

    for (RLMObjectSchema *objectSchema in _schema.objectSchema) {
        for (RLMObservationInfo *info : objectSchema->_observedObjects) {
            info->willChange(RLMInvalidatedKey);
            info->prepareForInvalidation();
        }
    }

    _sharedGroup->end_read();
    _group = nullptr;
    for (RLMObjectSchema *objectSchema in _schema.objectSchema) {
        for (RLMObservationInfo *info : objectSchema->_observedObjects) {
            info->didChange(RLMInvalidatedKey);
        }
        objectSchema.table = nullptr;
    }
}

/**
 Replaces all string columns in this Realm with a string enumeration column and compacts the
 database file.
 
 Cannot be called from a write transaction.

 Compaction will not occur if other `RLMRealm` instances exist.
 
 While compaction is in progress, attempts by other threads or processes to open the database will
 wait.
 
 Be warned that resource requirements for compaction is proportional to the amount of live data in
 the database.
 
 Compaction works by writing the database contents to a temporary database file and then replacing
 the database with the temporary one. The name of the temporary file is formed by appending
 `.tmp_compaction_space` to the name of the database.

 @return YES if the compaction succeeded.
 */
- (BOOL)compact
{
    RLMCheckThread(self);
    BOOL compactSucceeded = NO;
    if (!_inWriteTransaction) {
        try {
            for (RLMObjectSchema *objectSchema in _schema.objectSchema) {
                objectSchema.table->optimize();
            }
            _sharedGroup->end_read();
            compactSucceeded = _sharedGroup->compact();
            _sharedGroup->begin_read();
        }
        catch (std::exception& ex) {
            @throw RLMException(ex);
        }
    } else {
        @throw RLMException(@"Can't compact a Realm within a write transaction");
    }
    return compactSucceeded;
}

- (void)dealloc {
    if (_inWriteTransaction) {
        [self cancelWriteTransaction];
        NSLog(@"WARNING: An RLMRealm instance was deallocated during a write transaction and all "
              "pending changes have been rolled back. Make sure to retain a reference to the "
              "RLMRealm for the duration of the write transaction.");
    }
    [_notifier stop];
}

- (void)handleExternalCommit {
    RLMCheckThread(self);
    NSAssert(!_readOnly, @"Read-only realms do not have notifications");
    try {
        if (_sharedGroup->has_changed()) { // Throws
            if (_autorefresh) {
                if (_group) {
                    RLMAdvanceRead(*_sharedGroup, *_history, _schema);
                }
                [self sendNotifications:RLMRealmDidChangeNotification];
            }
            else {
                [self sendNotifications:RLMRealmRefreshRequiredNotification];
            }
        }
    }
    catch (std::exception &ex) {
        @throw RLMException(ex);
    }
}

- (BOOL)refresh {
    RLMCheckThread(self);
    CheckReadWrite(self, @"Cannot refresh a read-only realm (external modifications to read only realms are not supported)");

    // can't be any new changes if we're in a write transaction
    if (self.inWriteTransaction) {
        return NO;
    }

    try {
        // advance transaction if database has changed
        if (_sharedGroup->has_changed()) { // Throws
            if (_group) {
                RLMAdvanceRead(*_sharedGroup, *_history, _schema);
            }
            else {
                // Create the read transaction
                [self getOrCreateGroup];
            }
            [self sendNotifications:RLMRealmDidChangeNotification];
            return YES;
        }
        return NO;
    }
    catch (std::exception &ex) {
        @throw RLMException(ex);
    }
}

- (void)addObject:(__unsafe_unretained RLMObject *const)object {
    RLMAddObjectToRealm(object, self, false);
}

- (void)addObjects:(id<NSFastEnumeration>)array {
    for (RLMObject *obj in array) {
        if (![obj isKindOfClass:[RLMObject class]]) {
            NSString *msg = [NSString stringWithFormat:@"Cannot insert objects of type %@ with addObjects:. Only RLMObjects are supported.", NSStringFromClass(obj.class)];
            @throw RLMException(msg);
        }
        [self addObject:obj];
    }
}

- (void)addOrUpdateObject:(RLMObject *)object {
    // verify primary key
    if (!object.objectSchema.primaryKeyProperty) {
        NSString *reason = [NSString stringWithFormat:@"'%@' does not have a primary key and can not be updated", object.objectSchema.className];
        @throw RLMException(reason);
    }

    RLMAddObjectToRealm(object, self, true);
}

- (void)addOrUpdateObjectsFromArray:(id)array {
    for (RLMObject *obj in array) {
        [self addOrUpdateObject:obj];
    }
}

- (void)deleteObject:(RLMObject *)object {
    RLMDeleteObjectFromRealm(object, self);
}

- (void)deleteObjects:(id)array {
    if ([array respondsToSelector:@selector(realm)] && [array respondsToSelector:@selector(deleteObjectsFromRealm)]) {
        if (self != (RLMRealm *)[array realm]) {
            @throw RLMException(@"Can only delete objects from the Realm they belong to.");
        }
        [array deleteObjectsFromRealm];
    }
    else if ([array conformsToProtocol:@protocol(NSFastEnumeration)]) {
        for (id obj in array) {
            if ([obj isKindOfClass:RLMObjectBase.class]) {
                RLMDeleteObjectFromRealm(obj, self);
            }
        }
    }
    else {
        @throw RLMException(@"Invalid array type - container must be an RLMArray, RLMArray, or NSArray of RLMObjects");
    }
}

- (void)deleteAllObjects {
    RLMDeleteAllObjectsFromRealm(self);
}

- (RLMResults *)allObjects:(NSString *)objectClassName {
    return RLMGetObjects(self, objectClassName, nil);
}

- (RLMResults *)objects:(NSString *)objectClassName where:(NSString *)predicateFormat, ... {
    va_list args;
    RLM_VARARG(predicateFormat, args);
    return [self objects:objectClassName where:predicateFormat args:args];
}

- (RLMResults *)objects:(NSString *)objectClassName where:(NSString *)predicateFormat args:(va_list)args {
    return [self objects:objectClassName withPredicate:[NSPredicate predicateWithFormat:predicateFormat arguments:args]];
}

- (RLMResults *)objects:(NSString *)objectClassName withPredicate:(NSPredicate *)predicate {
    return RLMGetObjects(self, objectClassName, predicate);
}

- (RLMObject *)objectWithClassName:(NSString *)className forPrimaryKey:(id)primaryKey {
    return RLMGetObject(self, className, primaryKey);
}

+ (uint64_t)schemaVersionAtPath:(NSString *)realmPath error:(NSError **)error {
    return [RLMRealm schemaVersionAtPath:realmPath encryptionKey:nil error:error];
}

+ (uint64_t)schemaVersionAtPath:(NSString *)realmPath encryptionKey:(NSData *)key error:(NSError **)outError {
    key = RLMRealmValidatedEncryptionKey(key);
    RLMRealm *realm = RLMGetThreadLocalCachedRealmForPath(realmPath);
    if (!realm) {
        NSError *error;
        realm = [[RLMRealm alloc] initWithPath:realmPath key:key readOnly:YES inMemory:NO dynamic:YES error:&error];
        if (error) {
            RLMSetErrorOrThrow(error, outError);
            return RLMNotVersioned;
        }
    }

    return realm::ObjectStore::get_schema_version(realm.group);
}

+ (NSError *)migrateRealm:(RLMRealmConfiguration *)configuration {
    NSString *realmPath = configuration.path;
    if (RLMGetAnyCachedRealmForPath(realmPath)) {
        @throw RLMException(@"Cannot migrate Realms that are already open.");
    }

    NSData *key = configuration.encryptionKey;

    NSError *error;
    RLMRealm *realm = [[RLMRealm alloc] initWithPath:realmPath key:key readOnly:NO inMemory:NO dynamic:YES error:&error];
    if (error)
        return error;

    try {
        RLMUpdateRealmToSchemaVersion(realm, configuration.schemaVersion,
                                      configuration.customSchema ?: [RLMSchema.sharedSchema copy],
                                      [realm migrationBlock:configuration.migrationBlock key:key]);
    } catch (std::exception const& ex) {
        return RLMMakeError(RLMErrorFail, ex);
    } catch (NSException *ex) {
        return RLMMakeError(ex);
    }
    return nil;
}

- (RLMObject *)createObject:(NSString *)className withValue:(id)value {
    return (RLMObject *)RLMCreateObjectInRealmWithValue(self, className, value, false);
}

- (BOOL)writeCopyToPath:(NSString *)path key:(NSData *)key error:(NSError **)error {
    key = RLMRealmValidatedEncryptionKey(key);

    try {
        self.group->write(path.UTF8String, static_cast<const char *>(key.bytes));
        return YES;
    }
    catch (File::PermissionDenied &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFilePermissionDenied, ex);
        }
    }
    catch (File::Exists &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFileExists, ex);
        }
    }
    catch (File::AccessError &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFileAccessError, ex);
        }
    }
    catch (std::exception &ex) {
        if (error) {
            *error = RLMMakeError(RLMErrorFail, ex);
        }
    }

    return NO;
}

- (BOOL)writeCopyToPath:(NSString *)path error:(NSError **)error {
    return [self writeCopyToPath:path key:nil error:error];
}

- (BOOL)writeCopyToPath:(NSString *)path encryptionKey:(NSData *)key error:(NSError **)error {
    if (!key) {
        @throw RLMException(@"Encryption key must not be nil");
    }

    return [self writeCopyToPath:path key:key error:error];
}

- (void)registerEnumerator:(RLMFastEnumerator *)enumerator {
    if (!_collectionEnumerators) {
        _collectionEnumerators = [NSHashTable hashTableWithOptions:NSPointerFunctionsWeakMemory];
    }
    [_collectionEnumerators addObject:enumerator];

}

- (void)unregisterEnumerator:(RLMFastEnumerator *)enumerator {
    [_collectionEnumerators removeObject:enumerator];
}

@end
