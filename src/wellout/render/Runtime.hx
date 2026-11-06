package wellout.render;

import wellout.ByteWriter;

typedef HelperFunction = (arguments:Arguments, context:RenderContext) -> Dynamic;
typedef HelperWriter = (arguments:Arguments, context:RenderContext, writer:ByteWriter) -> Void;
typedef FilterFunction = (input:Dynamic, arguments:Arguments, context:RenderContext) -> Dynamic;

typedef FilterWriter = (input:Dynamic, arguments:Arguments, context:RenderContext,
    writer:ByteWriter) -> Void;

typedef SourceFunction = (arguments:Arguments, context:RenderContext) -> Dynamic;

class HelperImplementation {
    public final call:HelperFunction;
    public final writer:Null<HelperWriter>;

    public function new(call:HelperFunction, ?writer:HelperWriter) {
        this.call = call;
        this.writer = writer;
    }
}

class FilterImplementation {
    public final apply:FilterFunction;
    public final writer:Null<FilterWriter>;

    public function new(apply:FilterFunction, ?writer:FilterWriter) {
        this.apply = apply;
        this.writer = writer;
    }
}

/**
    The implementations behind a host contract's helpers, filters and
    sources. Writer forms write straight into the output, so formatting in
    output positions does not create strings. A new runtime holds the
    built-in filters; a host may replace any of them, for example `date`
    and `number` with locale-aware versions.
**/
class Runtime {
    final helpers:Map<String, HelperImplementation> = [];
    final filters:Map<String, FilterImplementation> = [];
    final sources:Map<String, SourceFunction> = [];

    public function new() {
        BuiltinFilters.install(this);
    }

    public function addHelper(name:String, call:HelperFunction, ?writer:HelperWriter):Runtime {
        helpers.set(name, new HelperImplementation(call, writer));
        return this;
    }

    public function addFilter(name:String, apply:FilterFunction, ?writer:FilterWriter):Runtime {
        filters.set(name, new FilterImplementation(apply, writer));
        return this;
    }

    public function addSource(name:String, load:SourceFunction):Runtime {
        sources.set(name, load);
        return this;
    }

    public function helper(name:String):Null<HelperImplementation> {
        return helpers.get(name);
    }

    public function filter(name:String):Null<FilterImplementation> {
        return filters.get(name);
    }

    public function source(name:String):Null<SourceFunction> {
        return sources.get(name);
    }
}
