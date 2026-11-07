package wellout.render;

import wellout.Result;
import wellout.check.ComponentLibrary;
import wellout.check.HostContract;
import wellout.render.TemplateImage.TemplateImageError;
import wellout.syntax.Diagnostic;
#if (target.threaded)
import sys.thread.Mutex;
#end

/**
    Templates checked against one contract and compiled for backend B,
    cached by name. A host keeps one set per template lookup chain, such as
    per theme version, and drops it when templates change. With a `store`,
    compiled templates are also kept between processes as images.
**/
class TemplateSet {
    public final contract:HostContract;
    public final runtime:Runtime;
    public final library:ComponentLibrary;
    public final rootNames:Array<String>;
    public final store:Null<TemplateStore>;

    final compiled:Map<String, Result<CompiledTemplate>> = [];
    #if (target.threaded)
    final lock = new Mutex();
    #end

    public function new(contract:HostContract, runtime:Runtime, library:ComponentLibrary,
            ?store:TemplateStore) {
        this.contract = contract;
        this.runtime = runtime;
        this.library = library;
        this.store = store;
        rootNames = contract.rootNames();
    }

    /** The compiled template, or a result with diagnostics; null value for an unknown name. **/
    public function template(name:String):Result<CompiledTemplate> {
        var cached = cachedTemplate(name);
        if (cached != null) {
            return cached;
        }
        var restored = restore(name);
        if (restored != null) {
            var result = new Result<CompiledTemplate>(restored, []);
            remember(name, result);
            return result;
        }
        var checked = library.check(name);
        if (checked == null) {
            var unknown = new Result<CompiledTemplate>(null, [
                new Diagnostic("unknown-template", 'Unknown template ${name}',
                    new wellout.syntax.Position(0, 1, 1))
            ]);
            return unknown;
        }
        var diagnostics = checked.diagnostics.copy();
        var result = if (checked.value == null || checked.hasErrors()) {
            new Result<CompiledTemplate>(null, diagnostics);
        } else {
            var template = TemplateCompiler.compile(checked.value, this, diagnostics);
            var failed = false;
            for (diagnostic in diagnostics) {
                if (diagnostic.isError()) {
                    failed = true;
                }
            }
            if (!failed && store != null) {
                store.save(name, TemplateImage.encode(template));
            }
            new Result(failed ? null : template, diagnostics);
        }
        remember(name, result);
        return result;
    }

    /** The stored image of `name` restored, or null to compile it; a stale image is ignored. **/
    function restore(name:String):Null<CompiledTemplate> {
        if (store == null || !library.has(name)) {
            return null;
        }
        var image = store.load(name);
        if (image == null) {
            return null;
        }
        try {
            var template = TemplateImage.decode(image, this);
            return template.name == name ? template : null;
        } catch (error:TemplateImageError) {
            return null;
        }
    }

    public function has(name:String):Bool {
        return library.has(name);
    }

    function cachedTemplate(name:String):Null<Result<CompiledTemplate>> {
        #if (target.threaded)
        lock.acquire();
        var found = compiled.get(name);
        lock.release();
        return found;
        #else
        return compiled.get(name);
        #end
    }

    function remember(name:String, result:Result<CompiledTemplate>):Void {
        #if (target.threaded)
        lock.acquire();
        compiled.set(name, result);
        lock.release();
        #else
        compiled.set(name, result);
        #end
    }
}
