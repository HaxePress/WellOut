package wellout.check;

/** "Did you mean …?" hints for misspelled names, by edit distance with transpositions. */
class Suggestions {
    public static function hint(name:String, candidates:Array<String>):Null<String> {
        var closest = closest(name, candidates);
        return closest == null ? null : 'Did you mean ${closest}?';
    }

    /** The candidate within a small edit distance of `name`, or null. **/
    public static function closest(name:String, candidates:Array<String>):Null<String> {
        var lowered = name.toLowerCase();
        var threshold = name.length <= 3 ? 1 : name.length <= 6 ? 2 : 3;
        var best:Null<String> = null;
        var bestDistance = threshold + 1;
        for (candidate in candidates) {
            if (candidate == name) {
                continue;
            }
            var candidateLowered = candidate.toLowerCase();
            if (candidateLowered == lowered) {
                return candidate;
            }
            var distance = editDistance(lowered, candidateLowered);
            if (distance < bestDistance) {
                best = candidate;
                bestDistance = distance;
            }
        }
        return best;
    }

    /** Optimal string alignment distance: a swap of two neighbours counts as one edit. **/
    static function editDistance(a:String, b:String):Int {
        var width = b.length + 1;
        var rows = [for (_ in 0...(a.length + 1) * width) 0];
        for (row in 0...a.length + 1) {
            rows[row * width] = row;
        }
        for (column in 0...width) {
            rows[column] = column;
        }
        for (row in 1...a.length + 1) {
            for (column in 1...width) {
                var cost = a.charCodeAt(row - 1) == b.charCodeAt(column - 1) ? 0 : 1;
                var best = minimum(rows[(row - 1) * width + column] + 1,
                    rows[row * width + column - 1] + 1,
                    rows[(row - 1) * width + column - 1] + cost);
                if (row > 1
                    && column > 1
                    && a.charCodeAt(row - 1) == b.charCodeAt(column - 2)
                    && a.charCodeAt(row - 2) == b.charCodeAt(column - 1)) {
                    var swapped = rows[(row - 2) * width + column - 2] + 1;
                    if (swapped < best) {
                        best = swapped;
                    }
                }
                rows[row * width + column] = best;
            }
        }
        return rows[a.length * width + b.length];
    }

    static inline function minimum(a:Int, b:Int, c:Int):Int {
        var smaller = a < b ? a : b;
        return smaller < c ? smaller : c;
    }
}
