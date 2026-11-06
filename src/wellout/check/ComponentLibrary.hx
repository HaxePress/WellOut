package wellout.check;

import wellout.Result;
import wellout.check.CheckedTemplate;
import wellout.check.ComponentSignature;
import wellout.syntax.Diagnostic;
import wellout.syntax.Parser;

/**
    Templates held as source, parsed and checked on first use. Resolving a
    name checks that component fully, so its signature carries the types of
    the values its slots expose. A component that reaches itself through
    its own calls resolves to an incomplete signature, which the caller
    reports.

    Libraries chain: names missing here are looked up in the fallback
    library, which models the host's lookup chain (SPEC §5.5), for example
    a theme over the core components.
**/
class ComponentLibrary implements ComponentResolver {
    final contract:HostContract;
    final fallback:Null<ComponentLibrary>;
    final trusted:Bool;
    final sources:Map<String, String> = [];
    final order:Array<String> = [];
    final results:Map<String, Result<CheckedTemplate>> = [];
    final checking:Map<String, Bool> = [];

    public function new(contract:HostContract, ?fallback:ComponentLibrary, trusted:Bool = true) {
        this.contract = contract;
        this.fallback = fallback;
        this.trusted = trusted;
    }

    public function add(name:String, source:String):ComponentLibrary {
        if (!sources.exists(name)) {
            order.push(name);
        }
        sources.set(name, source);
        results.clear();
        return this;
    }

    /** Whether this library itself defines `name`, without its fallback. **/
    public function owns(name:String):Bool {
        return sources.exists(name);
    }

    public function has(name:String):Bool {
        return sources.exists(name) || (fallback != null && fallback.has(name));
    }

    public function names():Array<String> {
        var all = order.copy();
        if (fallback != null) {
            for (name in fallback.names()) {
                if (!sources.exists(name)) {
                    all.push(name);
                }
            }
        }
        return all;
    }

    public function resolve(name:String):Null<ComponentSignature> {
        if (!sources.exists(name)) {
            return fallback == null ? null : fallback.resolve(name);
        }
        if (checking.exists(name)) {
            return new ComponentSignature(name, [], [], false, true);
        }
        var result = check(name);
        return result == null || result.value == null ? null : result.value.signature;
    }

    /** The parse and check result of one template, cached; null for an unknown name. */
    public function check(name:String):Null<Result<CheckedTemplate>> {
        if (!sources.exists(name)) {
            return fallback == null ? null : fallback.check(name);
        }
        var cached = results.get(name);
        if (cached != null) {
            return cached;
        }
        var source = sources.get(name);
        checking.set(name, true);
        var parsed = Parser.parse(source);
        var diagnostics:Array<Diagnostic> = parsed.diagnostics.copy();
        var checked = TemplateChecker.check(parsed.document, contract, this, name, trusted);
        checking.remove(name);
        for (diagnostic in checked.diagnostics) {
            diagnostics.push(diagnostic);
        }
        var value = parsed.hasErrors() ? null : checked.value;
        var result = new Result(value, diagnostics);
        results.set(name, result);
        return result;
    }

    /** The source a name resolves to, for diagnostics. */
    public function sourceOf(name:String):Null<String> {
        var source = sources.get(name);
        if (source != null) {
            return source;
        }
        return fallback == null ? null : fallback.sourceOf(name);
    }
}
