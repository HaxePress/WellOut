package wellout.render;

import wellout.check.CheckedTemplate;
import wellout.render.Eval;
import wellout.render.Ops;

class CompiledProp {
    public final name:String;
    public final slot:Int;
    public final defaultValue:Null<Eval>;

    public function new(name:String, slot:Int, defaultValue:Null<Eval>) {
        this.name = name;
        this.slot = slot;
        this.defaultValue = defaultValue;
    }
}

/**
    A template compiled for backend B (SPEC §13.3): an immutable op tree
    and the frame layout of its props, sources, loop variables and slot
    values. Compiled templates are shared between threads.
**/
class CompiledTemplate {
    public final name:String;

    /** The checked template it was compiled from; null when restored from a `TemplateImage`. **/
    public final checked:Null<CheckedTemplate>;

    public final rootNames:Array<String>;
    public var valueSlots(default, null):Int = 0;
    public var intSlots(default, null):Int = 0;
    public var props(default, null):Array<CompiledProp> = [];
    public var sources(default, null):Array<SourceEval> = [];
    public var body(default, null):Op = new EmptyOp();

    /** Fragment names this template declares, for hosts that route fragment requests. **/
    public var fragments(default, null):Array<String> = [];

    @:allow(wellout.render)
    var loopParents:Array<Int> = [];

    public function new(name:String, checked:Null<CheckedTemplate>, rootNames:Array<String>) {
        this.name = name;
        this.checked = checked;
        this.rootNames = rootNames;
    }

    @:allow(wellout.render)
    function allocateSlot():Int {
        return valueSlots++;
    }

    @:allow(wellout.render)
    function allocateLoop(parent:Int):Int {
        var id = loopParents.length;
        loopParents.push(parent);
        intSlots = loopParents.length * 2;
        return id;
    }

    /** Restores the frame layout recorded in a `TemplateImage`. **/
    @:allow(wellout.render)
    function restoreLayout(valueSlots:Int, loopParents:Array<Int>):Void {
        this.valueSlots = valueSlots;
        this.loopParents = loopParents;
        intSlots = loopParents.length * 2;
    }

    @:allow(wellout.render)
    function finish(props:Array<CompiledProp>, sources:Array<SourceEval>, body:Op,
            fragments:Array<String>):Void {
        this.props = props;
        this.sources = sources;
        this.body = body;
        this.fragments = fragments;
    }

    public function prop(name:String):Null<CompiledProp> {
        for (prop in props) {
            if (prop.name == name) {
                return prop;
            }
        }
        return null;
    }

    public function loadSources(context:RenderContext):Void {
        for (index in 0...sources.length) {
            sources[index].resolve(context);
        }
    }
}
