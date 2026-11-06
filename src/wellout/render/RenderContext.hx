package wellout.render;

import haxe.Exception;
import wellout.ByteWriter;
import wellout.check.CheckedTemplate.AssetKind;
import wellout.render.Ops;

/** Thrown when a render exceeds a budget (SPEC §12.3). */
class RenderBudgetExceeded extends Exception {}

/**
    The state of one render: value and loop frames, component invocations,
    call arguments, the head and asset collections, and fragment tracking.
    A context is reused across renders, so its arrays keep their size and a
    steady-state render allocates no frames.
**/
class RenderContext {
    public var host(default, null):RenderHost;
    public var out:ByteWriter;
    public var main(default, null):ByteWriter;
    public final head = new ByteWriter(1024);
    public final title = new ByteWriter(256);
    public final assets = new ByteWriter(512);
    public var linkMapper(default, null):Null<String->String> = null;

    /** The longest output in bytes, or 0 without a limit. **/
    public var maxOutput = 0;

    public var maxComponentDepth = 32;

    @:allow(wellout.render) var values:Array<Dynamic> = [];
    @:allow(wellout.render) var valueBase = 0;
    @:allow(wellout.render) var valueTop = 0;
    @:allow(wellout.render) var ints:Array<Int> = [];
    @:allow(wellout.render) var intBase = 0;
    @:allow(wellout.render) var intTop = 0;
    @:allow(wellout.render) var argumentValues:Array<Dynamic> = [];
    @:allow(wellout.render) var argumentTop = 0;
    @:allow(wellout.render) final arguments:Arguments;
    @:allow(wellout.render) var sites:Array<ComponentOp> = [];
    @:allow(wellout.render) var callerValueBases:Array<Int> = [];
    @:allow(wellout.render) var callerIntBases:Array<Int> = [];
    @:allow(wellout.render) var callerInvocations:Array<Int> = [];
    @:allow(wellout.render) var depths:Array<Int> = [];
    @:allow(wellout.render) var invocation = -1;
    @:allow(wellout.render) var invocationTop = 0;
    @:allow(wellout.render) var roots:Array<Dynamic> = [];
    @:allow(wellout.render) var rootLoaded:Array<Bool> = [];
    @:allow(wellout.render) var rootNames:Array<String> = [];
    @:allow(wellout.render) var titleDepth = 0x7FFFFFFF;
    @:allow(wellout.render) var headMark = -1;
    @:allow(wellout.render) var assetsMark = -1;
    @:allow(wellout.render) var assetKinds:Array<AssetKind> = [];
    @:allow(wellout.render) var assetPaths:Array<String> = [];
    @:allow(wellout.render) var needsRuntime = false;
    @:allow(wellout.render) var fragment:Null<String> = null;
    @:allow(wellout.render) var fragmentStart = -1;
    @:allow(wellout.render) var fragmentEnd = -1;

    public function new() {
        arguments = new Arguments(this);
    }

    @:allow(wellout.render)
    function begin(host:RenderHost, writer:ByteWriter, rootNames:Array<String>,
            fragment:Null<String>):Void {
        this.host = host;
        main = writer;
        out = writer;
        head.reset();
        title.reset();
        linkMapper = host.linkMapper();
        this.rootNames = rootNames;
        while (roots.length < rootNames.length) {
            roots.push(null);
            rootLoaded.push(false);
        }
        for (index in 0...rootLoaded.length) {
            rootLoaded[index] = false;
        }
        valueBase = 0;
        valueTop = 0;
        intBase = 0;
        intTop = 0;
        argumentTop = 0;
        invocation = -1;
        invocationTop = 0;
        titleDepth = 0x7FFFFFFF;
        headMark = -1;
        assetsMark = -1;
        assetKinds.resize(0);
        assetPaths.resize(0);
        needsRuntime = false;
        this.fragment = fragment;
        fragmentStart = -1;
        fragmentEnd = -1;
    }

    /** Drops references to request data so a pooled context keeps nothing alive. **/
    @:allow(wellout.render)
    function end():Void {
        for (index in 0...values.length) {
            values[index] = null;
        }
        for (index in 0...argumentValues.length) {
            argumentValues[index] = null;
        }
        for (index in 0...roots.length) {
            roots[index] = null;
        }
        for (index in 0...sites.length) {
            sites[index] = null;
        }
        host = null;
        main = null;
        out = null;
        linkMapper = null;
    }

    public function root(index:Int):Dynamic {
        if (!rootLoaded[index]) {
            roots[index] = host.root(rootNames[index]);
            rootLoaded[index] = true;
        }
        return roots[index];
    }

    /** The template depth of the current frame: 0 for the page, 1 for a component it calls. **/
    public var depth(get, never):Int;

    function get_depth():Int {
        return invocation < 0 ? 0 : depths[invocation];
    }

    @:allow(wellout.render)
    inline function slot(index:Int):Dynamic {
        return values[valueBase + index];
    }

    @:allow(wellout.render)
    inline function setSlot(index:Int, value:Dynamic):Void {
        values[valueBase + index] = value;
    }

    @:allow(wellout.render)
    function argumentValue(index:Int):Dynamic {
        return argumentValues[index];
    }

    /** Reserves `count` argument slots and returns the first. **/
    @:allow(wellout.render)
    function reserveArguments(count:Int):Int {
        var base = argumentTop;
        argumentTop += count;
        while (argumentValues.length < argumentTop) {
            argumentValues.push(null);
        }
        return base;
    }

    @:allow(wellout.render)
    function releaseArguments(base:Int):Void {
        for (index in base...argumentTop) {
            argumentValues[index] = null;
        }
        argumentTop = base;
    }

    /** Pushes a frame of `valueCount` values and `intCount` integers above the current top. **/
    @:allow(wellout.render)
    function reserveFrame(valueCount:Int, intCount:Int):Void {
        var valueEnd = valueTop + valueCount;
        while (values.length < valueEnd) {
            values.push(null);
        }
        var intEnd = intTop + intCount;
        while (ints.length < intEnd) {
            ints.push(0);
        }
    }

    @:allow(wellout.render)
    function pushInvocation(site:ComponentOp):Int {
        var index = invocationTop++;
        if (index >= sites.length) {
            sites.push(null);
            callerValueBases.push(0);
            callerIntBases.push(0);
            callerInvocations.push(-1);
            depths.push(0);
        }
        var depth = invocation < 0 ? 1 : depths[invocation] + 1;
        if (depth > maxComponentDepth) {
            invocationTop--;
            throw new RenderBudgetExceeded('Component depth ${depth} exceeds ${maxComponentDepth}');
        }
        sites[index] = site;
        callerValueBases[index] = valueBase;
        callerIntBases[index] = intBase;
        callerInvocations[index] = invocation;
        depths[index] = depth;
        return index;
    }

    @:allow(wellout.render)
    function addAsset(kind:AssetKind, path:String):Void {
        for (index in 0...assetPaths.length) {
            if (assetPaths[index] == path && assetKinds[index] == kind) {
                return;
            }
        }
        assetKinds.push(kind);
        assetPaths.push(path);
    }

    @:allow(wellout.render)
    function checkOutput():Void {
        if (maxOutput > 0 && main.length > maxOutput) {
            throw new RenderBudgetExceeded('Output exceeds ${maxOutput} bytes');
        }
    }
}
