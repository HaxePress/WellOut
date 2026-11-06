package wellout.check;

/** "Did you mean …?" hints for misspelled names, by edit distance. */
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

    /** Levenshtein distance. **/
    static function editDistance(a:String, b:String):Int {
        var previous = [for (column in 0...b.length + 1) column];
        var current = [for (column in 0...b.length + 1) 0];
        for (row in 1...a.length + 1) {
            current[0] = row;
            for (column in 1...b.length + 1) {
                var cost = a.charCodeAt(row - 1) == b.charCodeAt(column - 1) ? 0 : 1;
                var deletion = previous[column] + 1;
                var insertion = current[column - 1] + 1;
                var substitution = previous[column - 1] + cost;
                current[column] = minimum(deletion, insertion, substitution);
            }
            var swap = previous;
            previous = current;
            current = swap;
        }
        return previous[b.length];
    }

    static inline function minimum(a:Int, b:Int, c:Int):Int {
        var smaller = a < b ? a : b;
        return smaller < c ? smaller : c;
    }
}
