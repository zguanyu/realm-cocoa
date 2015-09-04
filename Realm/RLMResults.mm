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

#import "RLMResults_Private.h"

#import "RLMArray_Private.hpp"
#import "RLMObservation.hpp"
#import "RLMObjectSchema_Private.hpp"
#import "RLMObjectStore.h"
#import "RLMObject_Private.hpp"
#import "RLMQueryUtil.hpp"
#import "RLMRealm_Private.hpp"
#import "RLMSchema_Private.h"
#import "RLMUtil.hpp"

#import "results.hpp"

#import <objc/runtime.h>
#import <realm/table_view.hpp>

using namespace realm;

static const int RLMEnumerationBufferSize = 16;

@implementation RLMFastEnumerator {
    // The buffer supplied by fast enumeration does not retain the objects given
    // to it, but because we create objects on-demand and don't want them
    // autoreleased (a table can have more rows than the device has memory for
    // accessor objects) we need a thing to retain them.
    id _strongBuffer[RLMEnumerationBufferSize];

    RLMRealm *_realm;
    RLMObjectSchema *_objectSchema;

    // Collection being enumerated. Only one of these two will be valid: when
    // possible we enumerate the collection directly, but when in a write
    // transaction we instead create a frozen TableView and enumerate that
    // instead so that mutating the collection during enumeration works.
    id<RLMFastEnumerable> _collection;
    realm::TableView _tableView;
}

- (instancetype)initWithCollection:(id<RLMFastEnumerable>)collection objectSchema:(RLMObjectSchema *)objectSchema {
    self = [super init];
    if (self) {
        _realm = collection.realm;
        _objectSchema = objectSchema;

        if (_realm.inWriteTransaction) {
            _tableView = [collection tableView];
        }
        else {
            _collection = collection;
            [_realm registerEnumerator:self];
        }
    }
    return self;
}

- (void)dealloc {
    if (_collection) {
        [_realm unregisterEnumerator:self];
    }
}

- (void)detach {
    _tableView = [_collection tableView];
    _collection = nil;
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                    count:(NSUInteger)len {
    [_realm verifyThread];
    if (!_tableView.is_attached() && !_collection) {
        @throw RLMException(@"Collection is no longer valid");
    }
    // The fast enumeration buffer size is currently a hardcoded number in the
    // compiler so this can't actually happen, but just in case it changes in
    // the future...
    if (len > RLMEnumerationBufferSize) {
        len = RLMEnumerationBufferSize;
    }

    NSUInteger batchCount = 0, count = state->extra[1];

    Class accessorClass = _objectSchema.accessorClass;
    for (NSUInteger index = state->state; index < count && batchCount < len; ++index) {
        size_t row = _collection ? [_collection indexInSource:index] : _tableView.get_source_ndx(index);

        RLMObject *accessor = [[accessorClass alloc] initWithRealm:_realm schema:_objectSchema];
        accessor->_row = (*_objectSchema.table)[row];
        _strongBuffer[batchCount] = accessor;
        batchCount++;
    }

    for (NSUInteger i = batchCount; i < len; ++i) {
        _strongBuffer[i] = nil;
    }

    if (batchCount == 0) {
        // Release our data if we're done, as we're autoreleased and so may
        // stick around for a while
        _collection = nil;
        if (_tableView.is_attached()) {
            _tableView = TableView();
        }
        else {
            [_realm unregisterEnumerator:self];
        }
    }

    state->itemsPtr = (__unsafe_unretained id *)(void *)_strongBuffer;
    state->state += batchCount;
    state->mutationsPtr = state->extra+1;

    return batchCount;
}
@end

//
// RLMResults implementation
//
@implementation RLMResults {
    realm::Results _results;
    RLMRealm *_realm;
    NSString *_objectClassName;
}

- (instancetype)initPrivate {
    self = [super init];
    return self;
}

+ (instancetype)resultsWithObjectClassName:(NSString *)objectClassName
                                     realm:(RLMRealm *)realm
                                   results:(realm::Results)results {
    RLMResults *ar = [[self alloc] initPrivate];
    ar->_results = std::move(results);
    ar->_realm = realm;
    ar->_objectClassName = objectClassName;
    ar->_objectSchema = realm.schema[objectClassName];
    return ar;
}

//
// validation helper
//
static inline void RLMResultsValidateInWriteTransaction(__unsafe_unretained RLMResults *const ar) {
    ar->_realm->_realm->verify_thread();
    if (!ar->_realm->_realm->is_in_transaction()) {
        @throw RLMException(@"Can't mutate a persisted array outside of a write transaction.");
    }
}

//
// public method implementations
//
- (NSUInteger)count {
    return _results.size();
}

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(__unused __unsafe_unretained id [])buffer
                                    count:(NSUInteger)len {
    __autoreleasing RLMFastEnumerator *enumerator;
    if (state->state == 0) {
//        RLMResultsValidate(self);

        enumerator = [[RLMFastEnumerator alloc] initWithCollection:self objectSchema:_objectSchema];
        state->extra[0] = (long)enumerator;
        state->extra[1] = self.count;
    }
    else {
        enumerator = (__bridge id)(void *)state->extra[0];
    }

    return [enumerator countByEnumeratingWithState:state count:len];
}

- (NSUInteger)indexOfObjectWhere:(NSString *)predicateFormat, ... {
    va_list args;
    RLM_VARARG(predicateFormat, args);
    return [self indexOfObjectWhere:predicateFormat args:args];
}

- (NSUInteger)indexOfObjectWhere:(NSString *)predicateFormat args:(va_list)args {
    return [self indexOfObjectWithPredicate:[NSPredicate predicateWithFormat:predicateFormat
                                                                   arguments:args]];
}

- (NSUInteger)indexOfObjectWithPredicate:(NSPredicate *)predicate {
    Query query = _results.get_query();
    RLMUpdateQueryWithPredicate(&query, predicate, _realm.schema, _realm.schema[self.objectClassName]);
    size_t index = query.find();
    if (index == realm::not_found) {
        return NSNotFound;
    }
    return _results.index_of(index);
}

- (id)objectAtIndex:(NSUInteger)index {
    return RLMCreateObjectAccessor(_realm, _objectSchema, _results.get(index));
}

- (id)firstObject {
    auto row = _results.first();
    return row ? RLMCreateObjectAccessor(_realm, _objectSchema, *row) : nil;
}

- (id)lastObject {
    auto row = _results.last();
    return row ? RLMCreateObjectAccessor(_realm, _objectSchema, *row) : nil;
}

- (NSUInteger)indexOfObject:(RLMObject *)object {
    if (!object || !object->_realm) {
        return NSNotFound;
    }

    return RLMConvertNotFound(_results.index_of(object->_row));
}

- (id)valueForKey:(NSString *)key {
//    RLMResultsValidate(self);
    return RLMCollectionValueForKey(self, key);
}

- (void)setValue:(id)value forKey:(NSString *)key {
    RLMResultsValidateInWriteTransaction(self);
    RLMCollectionSetValueForKey(self, key, value);
}

- (RLMResults *)objectsWhere:(NSString *)predicateFormat, ... {
    // validate predicate
    va_list args;
    RLM_VARARG(predicateFormat, args);
    return [self objectsWhere:predicateFormat args:args];
}

- (RLMResults *)objectsWhere:(NSString *)predicateFormat args:(va_list)args {
    return [self objectsWithPredicate:[NSPredicate predicateWithFormat:predicateFormat arguments:args]];
}

- (RLMResults *)objectsWithPredicate:(NSPredicate *)predicate {
    auto query = _results.get_query();
    if (!query.get_table().get())
        return self;
    RLMUpdateQueryWithPredicate(&query, predicate, _realm.schema, _realm.schema[self.objectClassName]);
    return [RLMResults resultsWithObjectClassName:self.objectClassName
                                            realm:_realm
                                          results:realm::Results(_realm->_realm, std::move(query), _results.get_sort())];
}

- (RLMResults *)sortedResultsUsingProperty:(NSString *)property ascending:(BOOL)ascending {
    return [self sortedResultsUsingDescriptors:@[[RLMSortDescriptor sortDescriptorWithProperty:property ascending:ascending]]];
}

- (RLMResults *)sortedResultsUsingDescriptors:(NSArray *)properties {
    return [RLMResults resultsWithObjectClassName:self.objectClassName
                                            realm:_realm
                                          results:_results.sort(RLMSortOrderFromDescriptors(_objectSchema, properties))];
}

- (id)objectAtIndexedSubscript:(NSUInteger)index {
    return [self objectAtIndex:index];
}

static id mixedToObjc(realm::util::Optional<realm::Mixed> value) {
    if (!value) {
        return nil;
    }
    return RLMMixedToObjc(*value);
}

- (id)minOfProperty:(NSString *)property {
    return mixedToObjc(_results.min(RLMValidatedColumnIndex(_realm.schema[_objectClassName], property)));
//                                           reason:@"minOfProperty only supported for int, float, double and date properties."
}

- (id)maxOfProperty:(NSString *)property {
    return mixedToObjc(_results.max(RLMValidatedColumnIndex(_realm.schema[_objectClassName], property)));
}

- (id)sumOfProperty:(NSString *)property {
    return mixedToObjc(_results.sum(RLMValidatedColumnIndex(_realm.schema[_objectClassName], property)));
}

- (id)averageOfProperty:(NSString *)property {
    return mixedToObjc(_results.average(RLMValidatedColumnIndex(_realm.schema[_objectClassName], property)));
}

- (void)deleteObjectsFromRealm {
    // needs to do stuff for table stuff
    RLMTrackDeletions(_realm, ^{ _results.clear(); });
}

- (NSString *)description {
    const NSUInteger maxObjects = 100;
    NSMutableString *mString = [NSMutableString stringWithFormat:@"RLMResults <0x%lx> (\n", (long)self];
    unsigned long index = 0, skipped = 0;
    for (id obj in self) {
        NSString *sub;
        if ([obj respondsToSelector:@selector(descriptionWithMaxDepth:)]) {
            sub = [obj descriptionWithMaxDepth:RLMDescriptionMaxDepth - 1];
        }
        else {
            sub = [obj description];
        }

        // Indent child objects
        NSString *objDescription = [sub stringByReplacingOccurrencesOfString:@"\n" withString:@"\n\t"];
        [mString appendFormat:@"\t[%lu] %@,\n", index++, objDescription];
        if (index >= maxObjects) {
            skipped = self.count - maxObjects;
            break;
        }
    }

    // Remove last comma and newline characters
    if(self.count > 0)
        [mString deleteCharactersInRange:NSMakeRange(mString.length-2, 2)];
    if (skipped) {
        [mString appendFormat:@"\n\t... %lu objects skipped.", skipped];
    }
    [mString appendFormat:@"\n)"];
    return [NSString stringWithString:mString];
}

- (NSUInteger)indexInSource:(NSUInteger)index {
    return _results.index_of(index);
}

- (realm::TableView)tableView {
//    RLMResultsValidateAttached(self);
    return _results.get_query().find_all();
}

@end
