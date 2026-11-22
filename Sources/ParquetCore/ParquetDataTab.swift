import Foundation

// Logic for the Quick Look Data tab that runs after the preview is generated. Quick Look cannot
// call back into the extension, so filtering, sorting and the distinct-value list run as
// JavaScript over the rows embedded in the page. The script lives here (not in the extension) so
// Tests/core_tests.swift can run it through JavaScriptCore.
public enum ParquetDataTab {
    // How a column sorts and compares: "number", "date", "text" or "nested".
    public static func kind(forType typeName: String) -> String {
        let name = typeName.lowercased()
        if name.hasPrefix("date") || name.hasPrefix("timestamp") || name.hasPrefix("time") || name == "int96" {
            return "date"
        }
        for prefix in ["int", "uint", "float", "double", "decimal"] where name.hasPrefix(prefix) {
            return "number"
        }
        return "text"
    }

    // One kind per table column. Columns are matched to footer leaves by their top-level name;
    // partition keys and columns missing from the footer are "text".
    public static func columnKinds(names: [String], nested: [Bool], footerColumns: [ParquetFooter.Column]) -> [String] {
        var byName: [String: ParquetFooter.Column] = [:]
        for column in footerColumns {
            let top = column.path.first ?? column.name
            if byName[top] == nil { byName[top] = column }
        }
        return names.enumerated().map { index, name in
            if index < nested.count && nested[index] { return "nested" }
            guard let column = byName[name] else { return "text" }
            return kind(forType: column.logicalType)
        }
    }

    // Row counts offered by the "Show" menu; 0 means every loaded row.
    public static let showChoices = [10, 50, 100, 500, 1000, 0]

    // Pure functions, no DOM. `PQ.visible` takes rows as arrays of strings or null.
    //
    // Column filter syntax (also used by the Stats links):
    //   text        case-insensitive substring
    //   =text       exact value
    //   >n >=n <n <=n   numeric comparison (cells that are not numbers do not match)
    //   is null / not null
    public static let script = #"""
    var PQ = (function () {
      var UNREADABLE = '‹not read›';
      var collator = (typeof Intl !== 'undefined' && Intl.Collator)
        ? new Intl.Collator('en', { numeric: true, sensitivity: 'base' }) : null;

      function num(s) {
        if (s === null || s === undefined) { return null; }
        var t = String(s).trim();
        if (t === '' || !/^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(t)) { return null; }
        var v = Number(t);
        return isFinite(v) ? v : null;
      }

      function parseFilter(raw) {
        var s = String(raw === null || raw === undefined ? '' : raw).trim();
        if (s === '') { return null; }
        var low = s.toLowerCase();
        if (low === 'is null') { return { op: 'null' }; }
        if (low === 'not null') { return { op: 'notnull' }; }
        var m = /^(>=|<=|>|<|=)\s*([\s\S]*)$/.exec(s);
        if (m) {
          if (m[1] === '=') { return { op: 'eq', text: m[2] }; }
          var n = num(m[2]);
          if (n !== null) { return { op: m[1], num: n }; }
        }
        return { op: 'has', text: low };
      }

      function cellMatches(v, f) {
        if (v === UNREADABLE) { v = null; }
        switch (f.op) {
          case 'null': return v === null;
          case 'notnull': return v !== null;
          case 'eq': return v !== null && v === f.text;
          case 'has': return v !== null && v.toLowerCase().indexOf(f.text) >= 0;
        }
        var n = num(v);
        if (n === null) { return false; }
        if (f.op === '>') { return n > f.num; }
        if (f.op === '>=') { return n >= f.num; }
        if (f.op === '<') { return n < f.num; }
        return n <= f.num;
      }

      // needle: lowercased global filter ('' for none); filters: parsed filter or null per column.
      function rowMatches(row, needle, filters) {
        if (needle) {
          var any = false;
          for (var i = 0; i < row.length; i++) {
            if (row[i] !== null && row[i] !== UNREADABLE && row[i].toLowerCase().indexOf(needle) >= 0) { any = true; break; }
          }
          if (!any) { return false; }
        }
        for (var c = 0; c < filters.length; c++) {
          if (filters[c] && !cellMatches(c < row.length ? row[c] : null, filters[c])) { return false; }
        }
        return true;
      }

      function compareInts(a, b) {
        var na = a.charAt(0) === '-', nb = b.charAt(0) === '-';
        if (na !== nb) { return na ? -1 : 1; }
        var x = a.replace(/^[+-]?0*/, ''), y = b.replace(/^[+-]?0*/, '');
        var r = x.length !== y.length ? (x.length < y.length ? -1 : 1) : (x < y ? -1 : x > y ? 1 : 0);
        return na ? -r : r;
      }

      function compare(a, b, kind) {
        if (kind === 'number') {
          var ints = /^[+-]?\d+$/;
          if (ints.test(a) && ints.test(b)) { return compareInts(a, b); }
          var x = num(a), y = num(b);
          if (x !== null && y !== null) { return x < y ? -1 : x > y ? 1 : 0; }
        }
        if (collator) { return collator.compare(a, b); }
        var p = a.toLowerCase(), q = b.toLowerCase();
        return p < q ? -1 : p > q ? 1 : 0;
      }

      // Nulls (and unreadable cells) stay at the end in both directions; ties keep file order.
      function order(indexes, rows, col, dir, kind) {
        if (dir !== 'asc' && dir !== 'desc') { return indexes.slice(); }
        var present = [], missing = [];
        indexes.forEach(function (i) {
          var v = rows[i][col];
          (v === null || v === undefined || v === UNREADABLE ? missing : present).push(i);
        });
        var sign = dir === 'desc' ? -1 : 1;
        present.sort(function (i, j) {
          var r = compare(rows[i][col], rows[j][col], kind);
          return r !== 0 ? sign * r : i - j;
        });
        return present.concat(missing);
      }

      function cycle(dir) { return dir === 'asc' ? 'desc' : dir === 'desc' ? 'off' : 'asc'; }

      // q: {global, filters: [raw text per column], sortColumn, sortDir, show (0 = all)}.
      // Returns {indexes, matched}: the rows to draw and how many match before the cap.
      function visible(rows, kinds, q) {
        var needle = String(q.global || '').trim().toLowerCase();
        var filters = (q.filters || []).map(parseFilter);
        var matched = [];
        for (var i = 0; i < rows.length; i++) {
          if (rowMatches(rows[i], needle, filters)) { matched.push(i); }
        }
        var sorted = q.sortColumn === null || q.sortColumn === undefined ? matched
          : order(matched, rows, q.sortColumn, q.sortDir, kinds[q.sortColumn]);
        var cap = q.show > 0 ? q.show : sorted.length;
        return { indexes: sorted.slice(0, cap), matched: matched.length };
      }

      // Distinct values of one column over the given rows: most frequent first, then by value.
      // null is reported as the value null. At most `limit` values are returned; at most 10,000
      // are counted (capped is then true).
      function distinct(rows, indexes, col, limit) {
        var counts = new Map(), capped = false;
        for (var k = 0; k < indexes.length; k++) {
          var v = rows[indexes[k]][col];
          if (v === undefined || v === UNREADABLE) { v = null; }
          if (counts.has(v)) { counts.set(v, counts.get(v) + 1); }
          else if (counts.size < 10000) { counts.set(v, 1); }
          else { capped = true; }
        }
        var all = Array.from(counts.entries());
        all.sort(function (a, b) {
          if (a[1] !== b[1]) { return b[1] - a[1]; }
          if (a[0] === null) { return -1; }
          if (b[0] === null) { return 1; }
          return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0;
        });
        return { values: all.slice(0, limit), total: all.length, capped: capped };
      }

      // Filter text that selects exactly one distinct value.
      function exactFilter(v) { return v === null ? 'is null' : '=' + v; }

      return { num: num, parseFilter: parseFilter, cellMatches: cellMatches, rowMatches: rowMatches,
               compare: compare, order: order, cycle: cycle, visible: visible, distinct: distinct,
               exactFilter: exactFilter };
    })();
    """#
}
