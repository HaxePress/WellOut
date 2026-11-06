package wellout.render;

/**
    The arguments of one helper, filter or source call. Positional and
    named arguments of declared parameters are read by parameter index;
    extra named arguments, such as the values of `t(key, name: value)`, are
    read by name. A context reuses one instance for every call.
**/
class Arguments {
    final context:RenderContext;
    var base = 0;
    var count = 0;
    var extraNames:Array<String> = [];

    public function new(context:RenderContext) {
        this.context = context;
    }

    @:allow(wellout.render)
    function set(base:Int, count:Int, extraNames:Array<String>):Void {
        this.base = base;
        this.count = count;
        this.extraNames = extraNames;
    }

    /** The number of declared parameters. **/
    public var length(get, never):Int;

    inline function get_length():Int {
        return count;
    }

    public function get(index:Int):Dynamic {
        return index < count ? context.argumentValue(base + index) : null;
    }

    public function string(index:Int, fallback:String = ""):String {
        var value = get(index);
        return value == null ? fallback : Values.toText(value);
    }

    public function int(index:Int, fallback:Int = 0):Int {
        var value = get(index);
        return value == null ? fallback : Values.toInt(value);
    }

    public var extraCount(get, never):Int;

    inline function get_extraCount():Int {
        return extraNames.length;
    }

    public function extraName(index:Int):String {
        return extraNames[index];
    }

    public function extraValue(index:Int):Dynamic {
        return context.argumentValue(base + count + index);
    }

    /** An extra named argument by name, or null. **/
    public function named(name:String):Dynamic {
        for (index in 0...extraNames.length) {
            if (extraNames[index] == name) {
                return extraValue(index);
            }
        }
        return null;
    }
}
