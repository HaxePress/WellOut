package wellout.render;

import haxe.io.Bytes;
import wellout.ByteWriter;
import wellout.check.CheckedTemplate.AssetKind;
#if (target.threaded)
import sys.thread.Mutex;
#end

/** Options for one render. */
typedef RenderOptions = {
    /** Render only this fragment (SPEC §9.1). **/
    @:optional var fragment:String;

    /** The longest output in bytes; 0 means no limit. **/
    @:optional var maxOutput:Int;

    @:optional var maxComponentDepth:Int;
}

/**
    Renders compiled templates into a `ByteWriter`. Contexts are pooled,
    so a steady-state render reuses its frames, argument stacks and head
    buffers.
**/
class Renderer {
    static final pool:Array<RenderContext> = [];
    static inline final MAX_POOLED = 64;
    #if (target.threaded)
    static final lock = new Mutex();
    #end
    static final stylesheetOpen = Bytes.ofString('<link rel="stylesheet" href="');
    static final stylesheetClose = Bytes.ofString('">');
    static final fontOpen = Bytes.ofString('<link rel="preload" href="');
    // The checker allows these font files; each ending is written without building a string.
    static final fontSuffixes = [".woff2", ".woff", ".ttf", ".otf"];
    static final fontEnds = [
        for (suffix in fontSuffixes)
            Bytes.ofString('" as="font" type="font/${suffix.substr(1)}" crossorigin>')
    ];
    static final scriptOpen = Bytes.ofString('<script type="module" src="');
    static final nonceOpen = Bytes.ofString('" nonce="');
    static final scriptClose = Bytes.ofString('"></script>');

    /**
        Renders `template` with `props`, an object whose fields are the
        template's props. Returns false when a fragment was requested but
        the template does not render it.
    **/
    public static function render(template:CompiledTemplate, props:Dynamic, host:RenderHost,
            writer:ByteWriter, ?options:RenderOptions):Bool {
        var context = acquire();
        var fragment = options == null ? null : options.fragment;
        context.maxOutput = options == null || options.maxOutput == null ? 0 : options.maxOutput;
        context.maxComponentDepth = options == null
            || options.maxComponentDepth == null ? 32 : options.maxComponentDepth;
        var found = true;
        try {
            context.begin(host, writer, template.rootNames, fragment);
            renderPage(template, props, context);
            found = finish(context);
        } catch (error:Dynamic) {
            context.end();
            release(context);
            throw error;
        }
        context.end();
        release(context);
        return found;
    }

    static function renderPage(template:CompiledTemplate, props:Dynamic,
            context:RenderContext):Void {
        context.reserveFrame(template.valueSlots, template.intSlots);
        context.valueBase = 0;
        context.intBase = 0;
        context.valueTop = template.valueSlots;
        context.intTop = template.intSlots;
        for (prop in template.props) {
            var value:Dynamic = props == null ? null : Values.field(props, prop.name);
            if (value == null && prop.defaultValue != null) {
                value = prop.defaultValue.value(context);
            }
            context.values[prop.slot] = value;
        }
        template.loadSources(context);
        template.body.render(context);
        context.checkOutput();
    }

    static function finish(context:RenderContext):Bool {
        var main = context.main;
        if (context.fragment != null) {
            if (context.fragmentStart < 0) {
                return false;
            }
            main.keep(context.fragmentStart, context.fragmentEnd);
            return true;
        }
        var assets = context.assets;
        assets.reset();
        writeAssets(context, assets);
        var headMark = context.headMark;
        var assetsMark = context.assetsMark;
        if (assetsMark < 0 && assets.length > 0) {
            assetsMark = headMark >= 0 ? headMark : bodyEnd(main);
        }
        // Insert at the later offset first, so the earlier offset stays valid.
        if (assetsMark >= headMark) {
            if (assetsMark >= 0) {
                main.insert(assetsMark, assets);
            }
            insertHead(context, headMark);
        } else {
            insertHead(context, headMark);
            main.insert(assetsMark, assets);
        }
        return true;
    }

    static function insertHead(context:RenderContext, mark:Int):Void {
        if (mark < 0) {
            return;
        }
        context.main.insert(mark, context.head);
        context.main.insert(mark, context.title);
    }

    /** Where to place assets when a page has no `<Assets />`: before `</body>`, or the end. **/
    static function bodyEnd(writer:ByteWriter):Int {
        var bytes = writer.bytes;
        var marker = "</body>";
        var index = writer.length - marker.length;
        while (index >= 0) {
            var matches = true;
            for (offset in 0...marker.length) {
                if (bytes.get(index + offset) != StringTools.fastCodeAt(marker, offset)) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                return index;
            }
            index--;
        }
        return writer.length;
    }

    static function writeAssets(context:RenderContext, out:ByteWriter):Void {
        var host = context.host;
        // Fonts come first, so they download alongside the stylesheets that use them.
        for (index in 0...context.assetPaths.length) {
            if (context.assetKinds[index] == Font) {
                font(host.assetUrl(Font, context.assetPaths[index]), context.assetPaths[index],
                    out);
            }
        }
        for (index in 0...context.assetPaths.length) {
            var kind = context.assetKinds[index];
            if (kind == Font) {
                continue;
            }
            var url = host.assetUrl(kind, context.assetPaths[index]);
            if (kind == Css) {
                out.chunk(stylesheetOpen);
                out.text(url);
                out.chunk(stylesheetClose);
            } else {
                script(url, host.nonce(), out);
            }
        }
        if (context.needsRuntime) {
            script(host.runtimeScript(), host.nonce(), out);
        }
    }

    /** A preload for a font file; one the host cannot find is left out. **/
    static function font(url:String, path:String, out:ByteWriter):Void {
        if (url == "") {
            return;
        }
        for (index in 0...fontSuffixes.length) {
            if (StringTools.endsWith(path, fontSuffixes[index])) {
                out.chunk(fontOpen);
                out.text(url);
                out.chunk(fontEnds[index]);
                return;
            }
        }
    }

    static function script(url:String, nonce:String, out:ByteWriter):Void {
        out.chunk(scriptOpen);
        out.text(url);
        out.chunk(nonceOpen);
        out.text(nonce);
        out.chunk(scriptClose);
    }

    static function acquire():RenderContext {
        #if (target.threaded)
        lock.acquire();
        var context = pool.pop();
        lock.release();
        #else
        var context = pool.pop();
        #end
        return context == null ? new RenderContext() : context;
    }

    static function release(context:RenderContext):Void {
        #if (target.threaded)
        lock.acquire();
        if (pool.length < MAX_POOLED) {
            pool.push(context);
        }
        lock.release();
        #else
        if (pool.length < MAX_POOLED) {
            pool.push(context);
        }
        #end
    }
}
