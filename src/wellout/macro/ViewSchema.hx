package wellout.macro;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;
import haxe.macro.TypeTools;
#end

/**
    Builds host view types (SPEC §6.1) from Haxe typedefs at compile time:

    ```haxe
    ViewSchema.register(contract, ContentSummary, SiteView);
    ```

    Field types map to template types: `String`, `Int`, `Float`, `Bool`,
    `Date`, `wellout.Url`, `wellout.SafeHtml`, `Null<T>` and `@:optional`
    fields (nullable), `Array<T>` (List), `Map<String, T>` (Map) and other
    typedefs, which are registered too. `@:well.requires("capability")`
    tags a field for viewers with that capability and `@:well.private`
    hides a field from templates.
**/
class ViewSchema {
    public static macro function register(contract:Expr, types:Array<Expr>):Expr {
        var state = new SchemaState();
        for (type in types) {
            var name = haxe.macro.ExprTools.toString(type);
            var resolved = try Context.getType(name) catch (error:Dynamic) {
                Context.error('Unknown view type ${name}', type.pos);
            };
            state.view(resolved, type.pos);
        }
        var statements:Array<Expr> = [macro var target:wellout.check.HostContract = $contract];
        for (view in state.views) {
            statements.push(macro target.addView($view));
        }
        statements.push(macro target);
        return macro $b{statements};
    }
}

#if macro
private class SchemaState {
    public final views:Array<Expr> = [];

    final seen:Map<String, Bool> = [];

    public function new() {}

    /** Registers a typedef as a view type and returns its name. **/
    public function view(type:Type, position:Position):String {
        switch type {
            case TType(reference, _):
                var definition = reference.get();
                var name = definition.name;
                if (seen.exists(name)) {
                    return name;
                }
                seen.set(name, true);
                var fields = switch Context.follow(definition.type) {
                    case TAnonymous(anonymous): anonymous.get().fields;
                    default: Context.error('View type ${name} must be a structure', position);
                }
                var entries:Array<Expr> = [];
                for (field in fields) {
                    if (field.meta.has(":well.private")) {
                        continue;
                    }
                    var fieldType = wellType(field.type, field.pos);
                    if (field.meta.has(":optional")) {
                        fieldType = macro wellout.check.Types.nullable($fieldType);
                    }
                    var requires = requiredCapability(field);
                    var fieldName = field.name;
                    entries.push(macro new wellout.check.Types.FieldInfo($v{fieldName},
                        $fieldType, $requires));
                }
                views.push(macro new wellout.check.Types.RecordType($v{name}, $a{entries}));
                return name;
            default:
                return Context.error('View types are declared with typedef', position);
        }
    }

    static function requiredCapability(field:ClassField):Expr {
        for (entry in field.meta.get()) {
            if (entry.name == ":well.requires" && entry.params != null && entry.params.length == 1) {
                return entry.params[0];
            }
        }
        return macro null;
    }

    function wellType(type:Type, position:Position):Expr {
        switch type {
            case TAbstract(reference, parameters):
                var abstractType = reference.get();
                var path = abstractType.pack.concat([abstractType.name]).join(".");
                switch path {
                    case "Int":
                        return macro wellout.check.Types.WellType.TInt;
                    case "Float":
                        return macro wellout.check.Types.WellType.TFloat;
                    case "Bool":
                        return macro wellout.check.Types.WellType.TBool;
                    case "Null":
                        var inner = wellType(parameters[0], position);
                        return macro wellout.check.Types.nullable($inner);
                    case "wellout.Url":
                        return macro wellout.check.Types.WellType.TUrl;
                    case "wellout.SafeHtml":
                        return macro wellout.check.Types.WellType.TSafeHtml;
                    case "haxe.ds.Map":
                        return mapType(parameters, position);
                    default:
                        return wellType(abstractType.type, position);
                }
            case TInst(reference, parameters):
                var classType = reference.get();
                var path = classType.pack.concat([classType.name]).join(".");
                switch path {
                    case "String":
                        return macro wellout.check.Types.WellType.TString;
                    case "Date":
                        return macro wellout.check.Types.WellType.TDate;
                    case "Array":
                        var item = wellType(parameters[0], position);
                        return macro wellout.check.Types.WellType.TList($item);
                    case "haxe.ds.StringMap":
                        var value = wellType(parameters[0], position);
                        return macro wellout.check.Types.WellType.TMap($value);
                    default:
                        return
                            Context.error('${path} cannot be read by templates; declare a typedef',
                                position);
                }
            case TType(reference, parameters):
                var definition = reference.get();
                if (definition.pack.length == 0 && definition.name == "Null") {
                    var inner = wellType(parameters[0], position);
                    return macro wellout.check.Types.nullable($inner);
                }
                switch Context.follow(type) {
                    case TAnonymous(_):
                        var name = view(type, position);
                        return macro wellout.check.Types.WellType.TView($v{name});
                    default:
                        return wellType(TypeTools.follow(type, true), position);
                }
            case TLazy(load):
                return wellType(load(), position);
            case TDynamic(_):
                return macro wellout.check.Types.WellType.TAny;
            default:
                return Context.error('${TypeTools.toString(type)} cannot be read by templates',
                    position);
        }
    }

    function mapType(parameters:Array<Type>, position:Position):Expr {
        switch Context.follow(parameters[0]) {
            case TInst(reference, _) if (reference.get().name == "String"):
            default:
                Context.error("Map keys in view types are String", position);
        }
        var value = wellType(parameters[1], position);
        return macro wellout.check.Types.WellType.TMap($value);
    }
}
#end
