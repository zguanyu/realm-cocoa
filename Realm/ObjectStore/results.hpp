////////////////////////////////////////////////////////////////////////////
//
// Copyright 2015 Realm Inc.
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

#ifndef REALM_RESULTS_HPP
#define REALM_RESULTS_HPP

#import "shared_realm.hpp"

#import <realm/table_view.hpp>
#import <realm/table.hpp>
#import <realm/util/optional.hpp>

namespace realm {
template<typename T> class BasicRowExpr;
using RowExpr = BasicRowExpr<Table>;
class Mixed;

struct SortOrder {
    std::vector<size_t> columnIndices;
    std::vector<bool> ascending;

    explicit operator bool() const {
        return !columnIndices.empty();
    }
};

class Results {
public:
    Results() = default;
    Results(SharedRealm r, Table& table);
    Results(SharedRealm r, Query q, SortOrder s = {});

    Query get_query() const;
    SortOrder const& get_sort() const { return m_sort; }

    size_t size() const;
    RowExpr get(size_t index);

    util::Optional<RowExpr> first();
    util::Optional<RowExpr> last();

    size_t index_of(Row const& row);
    size_t index_of(size_t row_ndx);

    void clear();

    Results filter(Query&& q) const;
    Results sort(SortOrder&& sort) const;

    util::Optional<Mixed> max(size_t column);
    util::Optional<Mixed> min(size_t column);
    util::Optional<Mixed> average(size_t column);
    util::Optional<Mixed> sum(size_t column);

private:
    SharedRealm m_realm;
    Query m_query;
    TableView m_table_view;
    Table* m_table = nullptr;
    SortOrder m_sort;

    enum class Mode {
        Empty,
        Table,
        Query,
        TableView
    } m_mode = Mode::Empty;

    void validate_read() const;
    void validate_write() const;

    void materialize_tableview();

    template<typename Int, typename Float, typename Double, typename DateTime>
    util::Optional<Mixed> aggregate(size_t column, Int agg_int, Float agg_float,
                                    Double agg_double, DateTime agg_datetime);
};
}

#endif /* REALM_RESULTS_HPP */
