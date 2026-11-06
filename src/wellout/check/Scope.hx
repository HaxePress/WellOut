package wellout.check;

import wellout.check.Types;

/** Where a name comes from (SPEC §4.2). Implicit roots live in the host contract instead. */
enum BindingKind {
    Prop;
    Source;

    /** A loop variable or a scoped slot value. **/
    Variable;

    /** The `loop` metadata inside `:for`. **/
    Loop;
}

class Binding {
    public final name:String;
    public final kind:BindingKind;
    public final type:WellType;

    public function new(name:String, kind:BindingKind, type:WellType) {
        this.name = name;
        this.kind = kind;
        this.type = type;
    }
}

/**
    The names visible to an expression, with the facts a surrounding
    condition established: paths known to be non-null (§4.3) and
    capabilities known to be held (§6.2). Child scopes see their parents.
**/
class Scope {
    final parent:Null<Scope>;
    final bindings:Map<String, Binding> = [];
    final narrowedPaths:Map<String, Bool> = [];
    final heldCapabilities:Map<String, Bool> = [];

    public function new(?parent:Scope) {
        this.parent = parent;
    }

    public function child():Scope {
        return new Scope(this);
    }

    public function bind(name:String, kind:BindingKind, type:WellType):Scope {
        bindings.set(name, new Binding(name, kind, type));
        return this;
    }

    public function lookup(name:String):Null<Binding> {
        var binding = bindings.get(name);
        if (binding != null) {
            return binding;
        }
        return parent == null ? null : parent.lookup(name);
    }

    /** Marks a path key such as `post.image` as non-null in this scope. **/
    public function narrow(key:String):Scope {
        narrowedPaths.set(key, true);
        return this;
    }

    public function isNarrowed(key:String):Bool {
        if (narrowedPaths.exists(key)) {
            return true;
        }
        return parent != null && parent.isNarrowed(key);
    }

    /** Records that a `can(capability)` guard holds in this scope. **/
    public function guard(capability:String):Scope {
        heldCapabilities.set(capability, true);
        return this;
    }

    public function isGuarded(capability:String):Bool {
        if (heldCapabilities.exists(capability)) {
            return true;
        }
        return parent != null && parent.isGuarded(capability);
    }

    /** Every visible name, innermost first, for suggestions. **/
    public function names():Array<String> {
        var found:Array<String> = [];
        var seen:Map<String, Bool> = [];
        var scope = this;
        while (scope != null) {
            for (name in scope.bindings.keys()) {
                if (!seen.exists(name)) {
                    seen.set(name, true);
                    found.push(name);
                }
            }
            scope = scope.parent;
        }
        return found;
    }
}
