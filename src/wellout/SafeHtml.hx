package wellout;

/**
    HTML produced by trusted host code, such as a content renderer or a
    sanitizer, written without escaping (SPEC §8.3). Templates cannot
    create it.
**/
abstract SafeHtml(String) to String {
    inline function new(html:String) {
        this = html;
    }

    /** Marks markup as safe. Only call it on the output of a renderer or sanitizer. **/
    public static inline function trust(html:String):SafeHtml {
        return new SafeHtml(html);
    }
}
