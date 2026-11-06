package wellout.render;

/** URL checks for URL attributes (SPEC §8.2). */
class Urls {
    /** Not allowed: written as an empty value. **/
    public static inline final UNSAFE = 0;

    /** A path on this site, such as `/content`, which passes through the link base. **/
    public static inline final SITE = 1;

    /** Allowed and written as it is: relative paths, fragments, queries and allowed schemes. **/
    public static inline final SAFE = 2;

    /** A static prefix that does not decide the scheme yet, so the full value is checked. **/
    public static inline final UNDECIDED = 3;

    static final allowed = ["http", "https", "mailto", "tel"];

    public static function classify(url:String):Int {
        return classifyPrefix(url, true);
    }

    /**
        Classifies a URL or, when `complete` is false, a static prefix that
        interpolated values follow. Browsers drop leading spaces and control
        characters and ignore tabs and newlines inside a URL, so the scheme
        is read the same way.
    **/
    public static function classifyPrefix(url:String, complete:Bool):Int {
        var length = url.length;
        var start = 0;
        while (start < length && StringTools.fastCodeAt(url, start) <= 0x20) {
            start++;
        }
        if (start == length) {
            return complete ? SAFE : UNDECIDED;
        }
        var first = StringTools.fastCodeAt(url, start);
        if (first == "/".code || first == "\\".code) {
            if (start + 1 == length) {
                return complete ? SITE : UNDECIDED;
            }
            var second = StringTools.fastCodeAt(url, start + 1);
            // A protocol-relative URL leaves this site, so it is written without the link base.
            return second == "/".code || second == "\\".code ? SAFE : SITE;
        }
        if (first == "#".code || first == "?".code) {
            return SAFE;
        }
        var schemeLike = true;
        for (index in start...length) {
            var code = StringTools.fastCodeAt(url, index);
            if (code == ":".code) {
                if (!schemeLike) {
                    return SAFE;
                }
                return allowedScheme(url, start, index) ? SAFE : UNSAFE;
            }
            if (code == "/".code || code == "?".code || code == "#".code) {
                return SAFE;
            }
            if (code == "\t".code || code == "\n".code || code == "\r".code) {
                continue;
            }
            var schemeCharacter = (code >= "a".code && code <= "z".code)
                || (code >= "A".code && code <= "Z".code)
                || (code >= "0".code && code <= "9".code)
                || code == "+".code
                || code == "-".code
                || code == ".".code;
            if (!schemeCharacter) {
                schemeLike = false;
            }
        }
        return complete || !schemeLike ? SAFE : UNDECIDED;
    }

    static function allowedScheme(url:String, start:Int, end:Int):Bool {
        for (scheme in allowed) {
            if (schemeEquals(url, start, end, scheme)) {
                return true;
            }
        }
        return false;
    }

    /** Compares a scheme case-insensitively, skipping tabs and newlines as browsers do. **/
    static function schemeEquals(url:String, start:Int, end:Int, scheme:String):Bool {
        var position = 0;
        for (index in start...end) {
            var code = StringTools.fastCodeAt(url, index);
            if (code == "\t".code || code == "\n".code || code == "\r".code) {
                continue;
            }
            if (position >= scheme.length) {
                return false;
            }
            var lowered = code >= "A".code && code <= "Z".code ? code + 32 : code;
            if (lowered != StringTools.fastCodeAt(scheme, position)) {
                return false;
            }
            position++;
        }
        return position == scheme.length;
    }
}
