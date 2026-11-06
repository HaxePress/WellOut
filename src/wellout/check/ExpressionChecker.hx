package wellout.check;

import wellout.Result;
import wellout.check.Scope;
import wellout.check.TypedExpr;
import wellout.check.Types;
import wellout.syntax.Diagnostic;
import wellout.syntax.Expr;
import wellout.syntax.Position;

/** Thrown after an error is recorded; an expression stops at its first error. */
private class CheckFailure {
    public function new() {}
}

/**
    Infers the type of an expression against a scope and a host contract
    (SPEC §4.3), resolving every name, field, helper and filter. Errors
    stop the expression; warnings, such as a capability-tagged field read
    outside a `can()` guard, are recorded and checking continues.
**/
class ExpressionChecker {
    static final nullHint = "Supply a value with ?? or test it with :if";
    static final noBindings:Map<String, WellType> = [];

    final contract:HostContract;
    final diagnostics:Array<Diagnostic> = [];

    public static function check(expression:Expr, scope:Scope,
            contract:HostContract):Result<TypedExpr> {
        var checker = new ExpressionChecker(contract);
        try {
            var typed = checker.expression(expression, scope);
            return new Result(typed, checker.diagnostics);
        } catch (failure:CheckFailure) {
            return new Result(null, checker.diagnostics);
        }
    }

    /**
        Checks a `<sources>` entry: a call of a host source function whose
        arguments are literals, lists and records of literals, or context
        paths. Every argument becomes part of the source's cache key.
    **/
    public static function checkSourceCall(expression:Expr, scope:Scope,
            contract:HostContract):Result<TypedExpr> {
        var checker = new ExpressionChecker(contract);
        try {
            var typed = checker.sourceCall(expression, scope);
            return new Result(typed, checker.diagnostics);
        } catch (failure:CheckFailure) {
            return new Result(null, checker.diagnostics);
        }
    }

    function new(contract:HostContract) {
        this.contract = contract;
    }

    function sourceCall(expression:Expr, scope:Scope):TypedExpr {
        switch expression.kind {
            case Call(name, arguments):
                var source = contract.source(name);
                if (source == null) {
                    fail("unknown-source", 'Unknown source function ${name}', expression.position,
                        Suggestions.hint(name, contract.sourceNames()));
                }
                for (argument in arguments) {
                    requireStaticArgument(argument.value);
                }
                var bindings:Map<String, WellType> = [];
                var typedArguments = bindArguments(name, source.parameters, false, arguments,
                    scope, bindings, expression.position);
                var type = Types.substitute(source.returnType, bindings);
                return typed(SourceCall(source, typedArguments), type, expression.position);
            default:
                return fail("invalid-source", "A source is a call of a source function",
                    expression.position, "Write name=\"entries(collection: 'entry', limit: 3)\"");
        }
    }

    /** Source arguments are literals or context paths, so they can form a cache key. **/
    function requireStaticArgument(value:Expr):Void {
        switch value.kind {
            case StringLiteral(_) | IntLiteral(_) | FloatLiteral(_) | BoolLiteral(_) | NullLiteral:
            case Path(_, segments):
                for (segment in segments) {
                    switch segment {
                        case Index(key, _):
                            requireStaticArgument(key);
                        default:
                    }
                }
            case Unary(Negate, operand):
                requireStaticArgument(operand);
            case ListLiteral(items):
                for (item in items) {
                    requireStaticArgument(item);
                }
            case RecordLiteral(entries):
                for (entry in entries) {
                    requireStaticArgument(entry.value);
                }
            default:
                fail("source-argument", "Source arguments are literals or context paths",
                    value.position, "Compute values in the host's source function instead");
        }
    }

    function expression(expression:Expr, scope:Scope):TypedExpr {
        var at = expression.position;
        return switch expression.kind {
            case StringLiteral(value):
                typed(Constant(CString(value)), TString, at);
            case IntLiteral(value):
                typed(Constant(CInt(value)), TInt, at);
            case FloatLiteral(value):
                typed(Constant(CFloat(value)), TFloat, at);
            case BoolLiteral(value):
                typed(Constant(CBool(value)), TBool, at);
            case NullLiteral:
                typed(Constant(CNull), TNullable(TAny), at);
            case Path(root, segments):
                path(root, segments, scope, at);
            case Call(name, arguments):
                call(name, arguments, scope, at);
            case Filter(target, name, arguments, namePosition):
                filter(target, name, arguments, namePosition, scope, at);
            case ListLiteral(items):
                list(items, scope, at);
            case RecordLiteral(entries):
                record(entries, scope, at);
            case Unary(operation, operand):
                unary(operation, operand, scope, at);
            case Binary(operation, left, right, operatorPosition):
                binary(operation, left, right, operatorPosition, scope, at);
            case Conditional(condition, consequent, alternative):
                conditional(condition, consequent, alternative, scope, at);
        }
    }

    function path(root:String, segments:Array<PathSegment>, scope:Scope, at:Position):TypedExpr {
        var node = rootNode(root, scope, at);
        var key:Null<String> = root;
        node = narrowed(node, key, scope);
        for (segment in segments) {
            switch segment {
                case Field(name, position):
                    node = fieldAccess(node, name, position, scope, at);
                case Index(keyExpression, position):
                    var typedKey = expression(keyExpression, scope);
                    node = indexAccess(node, typedKey, position, at);
            }
            key = ConditionFacts.extend(key, segment);
            node = narrowed(node, key, scope);
        }
        return node;
    }

    function rootNode(root:String, scope:Scope, at:Position):TypedExpr {
        var binding = scope.lookup(root);
        if (binding != null) {
            return typed(Name(root, binding.kind), binding.type, at);
        }
        var rootType = contract.root(root);
        if (rootType != null) {
            return typed(Root(root), rootType, at);
        }
        var candidates = scope.names().concat(contract.rootNames());
        return fail("unknown-name", 'Unknown name ${root}', at, Suggestions.hint(root, candidates));
    }

    /** The node with a non-null type when the scope established that its path is non-null. **/
    function narrowed(node:TypedExpr, key:Null<String>, scope:Scope):TypedExpr {
        if (key != null && Types.isNullable(node.type) && scope.isNarrowed(key)) {
            return typed(node.kind, Types.nonNull(node.type), node.position);
        }
        return node;
    }

    /** `node.name`; problems point at the segment, the node at the path start. **/
    function fieldAccess(node:TypedExpr, name:String, position:Position, scope:Scope,
            at:Position):TypedExpr {
        var nullable = Types.isNullable(node.type);
        switch Types.nonNull(node.type) {
            case TView(viewName):
                var view = contract.viewType(viewName);
                if (view == null) {
                    fail("unknown-view-type", 'View type ${viewName} is not declared by the host',
                        position);
                }
                var field = view.field(name);
                if (field == null) {
                    fail("unknown-field", '${viewName} has no field ${name}', position,
                        Suggestions.hint(name, view.fieldNames()));
                }
                if (field.requires != null && !scope.isGuarded(field.requires)) {
                    warn("unguarded-field",
                        'Field ${name} is loaded only for viewers with ${field.requires}',
                        position, 'Read it inside :if="can(\'${field.requires}\')"');
                }
                var type = nullable ? Types.nullable(field.type) : field.type;
                return typed(FieldAccess(node, view, field), type, at);
            case TRecord(fields):
                var field = findField(fields, name);
                if (field == null) {
                    fail("unknown-field", 'The record has no field ${name}', position,
                        Suggestions.hint(name, [for (field in fields) field.name]));
                }
                var type = nullable ? Types.nullable(field.type) : field.type;
                return typed(FieldAccess(node, null, field), type, at);
            case base:
                return fail("no-fields", '${Types.print(base)} has no fields', position);
        }
    }

    function indexAccess(node:TypedExpr, key:TypedExpr, position:Position, at:Position):TypedExpr {
        switch Types.nonNull(node.type) {
            case TList(item):
                requireKey(key, TInt, "Lists");
                return typed(IndexAccess(node, key), Types.nullable(item), at);
            case TMap(value):
                requireKey(key, TString, "Maps");
                return typed(IndexAccess(node, key), Types.nullable(value), at);
            case base:
                return fail("not-indexable", 'Cannot index ${Types.print(base)}', position);
        }
    }

    function requireKey(key:TypedExpr, expected:WellType, what:String):Void {
        if (!Types.assignable(key.type, expected, noBindings)) {
            fail("index-type",
                '${what} are indexed with ${Types.print(expected)}, not ${Types.print(key.type)}',
                key.position);
        }
    }

    function call(name:String, arguments:Array<Argument>, scope:Scope, at:Position):TypedExpr {
        var helper = contract.helper(name);
        if (helper == null) {
            fail("unknown-helper", 'Unknown helper ${name}', at,
                Suggestions.hint(name, contract.helperNames()));
        }
        var bindings:Map<String, WellType> = [];
        var typedArguments = bindArguments(name, helper.parameters, helper.acceptsNamedRest,
            arguments, scope, bindings, at);
        var type = Types.substitute(helper.returnType, bindings);
        return typed(HelperCall(helper, typedArguments), type, at);
    }

    function filter(target:Expr, name:String, arguments:Array<Argument>, namePosition:Position,
            scope:Scope, at:Position):TypedExpr {
        var typedTarget = expression(target, scope);
        var filter = contract.filter(name);
        if (filter == null) {
            fail("unknown-filter", 'Unknown filter ${name}', namePosition,
                Suggestions.hint(name, contract.filterNames()));
        }
        var bindings:Map<String, WellType> = [];
        // A filter that does not accept null is skipped for a null input (null-safe, like paths).
        var propagatesNull = Types.isNullable(typedTarget.type)
            && !Types.isNullable(filter.input) && filter.input != TAny;
        var input = propagatesNull ? Types.nonNull(typedTarget.type) : typedTarget.type;
        if (!Types.assignable(input, filter.input, bindings)) {
            var expected = Types.print(filter.input);
            var got = Types.print(typedTarget.type);
            fail("filter-input", 'Filter ${name} expects ${expected} but got ${got}', namePosition);
        }
        var typedArguments = bindArguments('filter ${name}', filter.parameters, false, arguments,
            scope, bindings, namePosition);
        var type = Types.substitute(filter.returnType, bindings);
        if (propagatesNull) {
            type = Types.nullable(type);
        }
        return typed(FilterCall(typedTarget, filter, typedArguments), type, at);
    }

    /** Matches arguments to parameters by position and name, checking each type. **/
    function bindArguments(owner:String, parameters:Array<Parameter>, acceptsNamedRest:Bool,
            arguments:Array<Argument>, scope:Scope, bindings:Map<String, WellType>,
            at:Position):Array<TypedArgument> {
        var typedArguments:Array<TypedArgument> = [];
        var provided:Map<String, Bool> = [];
        var positional = 0;
        for (argument in arguments) {
            var value = expression(argument.value, scope);
            var parameter:Null<Parameter> = null;
            if (argument.name == null) {
                if (positional >= parameters.length) {
                    fail("too-many-arguments", '${owner} takes ${parameters.length} argument(s)',
                        argument.position);
                }
                parameter = parameters[positional++];
            } else {
                parameter = findParameter(parameters, argument.name);
                if (parameter == null && !acceptsNamedRest) {
                    var names = [for (parameter in parameters) parameter.name];
                    fail("unknown-argument", '${owner} has no argument ${argument.name}',
                        argument.position, Suggestions.hint(argument.name, names));
                }
            }
            if (parameter != null) {
                if (provided.exists(parameter.name)) {
                    fail("duplicate-argument",
                        'The argument ${parameter.name} of ${owner} is given twice',
                        argument.position);
                }
                provided.set(parameter.name, true);
                if (!Types.assignable(value.type, parameter.type, bindings)) {
                    var expected = Types.print(Types.substitute(parameter.type, bindings));
                    var got = Types.print(value.type);
                    fail("argument-type",
                        'Argument ${parameter.name} of ${owner} expects ${expected} but got ${got}',
                        value.position, nullableHint(value.type, parameter.type));
                }
            }
            typedArguments.push(new TypedArgument(argument.name, parameter, value));
        }
        for (parameter in parameters) {
            if (!parameter.optional && !provided.exists(parameter.name)) {
                fail("missing-argument", '${owner} needs the argument ${parameter.name}', at);
            }
        }
        return typedArguments;
    }

    function list(items:Array<Expr>, scope:Scope, at:Position):TypedExpr {
        var typedItems:Array<TypedExpr> = [];
        var itemType = TAny;
        for (item in items) {
            var typedItem = expression(item, scope);
            var joined = Types.unify(itemType, typedItem.type);
            if (joined == null) {
                var types = '${Types.print(itemType)} and ${Types.print(typedItem.type)}';
                fail("list-item-type", 'List entries must have one type but got ${types}',
                    typedItem.position);
            }
            itemType = joined;
            typedItems.push(typedItem);
        }
        return typed(ListValue(typedItems), TList(itemType), at);
    }

    function record(entries:Array<RecordEntry>, scope:Scope, at:Position):TypedExpr {
        var typedEntries:Array<TypedEntry> = [];
        var fields:Array<FieldInfo> = [];
        for (entry in entries) {
            var value = expression(entry.value, scope);
            typedEntries.push(new TypedEntry(entry.name, value));
            fields.push(new FieldInfo(entry.name, value.type));
        }
        return typed(RecordValue(typedEntries), TRecord(fields), at);
    }

    function unary(operation:UnaryOperator, operand:Expr, scope:Scope, at:Position):TypedExpr {
        var typedOperand = expression(operand, scope);
        switch operation {
            case Not:
                return typed(UnaryOp(Not, typedOperand), TBool, at);
            case Negate:
                requireNumber(typedOperand, "-");
                return typed(UnaryOp(Negate, typedOperand), typedOperand.type, at);
        }
    }

    function binary(operation:BinaryOperator, left:Expr, right:Expr, operatorPosition:Position,
            scope:Scope, at:Position):TypedExpr {
        var typedLeft = expression(left, scope);
        switch operation {
            case And:
                var narrowedScope = scope.child();
                ConditionFacts.of(left).applyTo(narrowedScope);
                var typedRight = expression(right, narrowedScope);
                return typed(BinaryOp(And, typedLeft, typedRight), TBool, at);
            case Or:
                var typedRight = expression(right, scope);
                return typed(BinaryOp(Or, typedLeft, typedRight), TBool, at);
            case Coalesce:
                var typedRight = expression(right, scope);
                var joined = Types.unify(Types.nonNull(typedLeft.type), typedRight.type);
                if (joined == null) {
                    var types = pairText(typedLeft, typedRight);
                    fail("coalesce-type", '?? needs values of one type but got ${types}',
                        operatorPosition);
                }
                return typed(BinaryOp(Coalesce, typedLeft, typedRight), joined, at);
            case Add | Subtract | Multiply | Divide | Modulo:
                var typedRight = expression(right, scope);
                var symbol = operatorSymbol(operation);
                requireNumber(typedLeft, symbol);
                requireNumber(typedRight, symbol);
                var type = if (operation == Divide) {
                    TFloat;
                } else if (typedLeft.type == TInt && typedRight.type == TInt) {
                    TInt;
                } else {
                    TFloat;
                }
                return typed(BinaryOp(operation, typedLeft, typedRight), type, at);
            case Equal | NotEqual:
                var typedRight = expression(right, scope);
                var leftBase = Types.nonNull(typedLeft.type);
                var rightBase = Types.nonNull(typedRight.type);
                if (Types.unify(leftBase, rightBase) == null) {
                    fail("comparison-type", cannotCompare(typedLeft, typedRight), operatorPosition);
                }
                return typed(BinaryOp(operation, typedLeft, typedRight), TBool, at);
            case Less | LessOrEqual | Greater | GreaterOrEqual:
                var typedRight = expression(right, scope);
                var symbol = operatorSymbol(operation);
                requireOrdered(typedLeft, symbol);
                requireOrdered(typedRight, symbol);
                var bothNumbers = Types.isNumber(typedLeft.type) && Types.isNumber(typedRight.type);
                if (!bothNumbers && !Types.same(typedLeft.type, typedRight.type)) {
                    fail("comparison-type", cannotCompare(typedLeft, typedRight), operatorPosition);
                }
                return typed(BinaryOp(operation, typedLeft, typedRight), TBool, at);
            case In:
                var typedRight = expression(right, scope);
                switch Types.nonNull(typedRight.type) {
                    case TList(item):
                        if (!Types.assignable(Types.nonNull(typedLeft.type), item, noBindings)) {
                            var got = Types.print(typedLeft.type);
                            fail("membership-type",
                                'in searches a list of ${Types.print(item)} but got ${got}',
                                operatorPosition);
                        }
                    default:
                        fail("membership-type",
                            'in needs a list but got ${Types.print(typedRight.type)}',
                            operatorPosition);
                }
                return typed(BinaryOp(In, typedLeft, typedRight), TBool, at);
        }
    }

    function conditional(condition:Expr, consequent:Expr, alternative:Null<Expr>, scope:Scope,
            at:Position):TypedExpr {
        var typedCondition = expression(condition, scope);
        var narrowedScope = scope.child();
        ConditionFacts.of(condition).applyTo(narrowedScope);
        var typedConsequent = expression(consequent, narrowedScope);
        if (alternative == null) {
            var type = Types.nullable(typedConsequent.type);
            return typed(Choice(typedCondition, typedConsequent, null), type, at);
        }
        var typedAlternative = expression(alternative, scope);
        var joined = Types.unify(typedConsequent.type, typedAlternative.type);
        if (joined == null) {
            var types = pairText(typedConsequent, typedAlternative);
            fail("branch-type", 'The branches have different types: ${types}',
                typedAlternative.position);
        }
        return typed(Choice(typedCondition, typedConsequent, typedAlternative), joined, at);
    }

    function requireNumber(value:TypedExpr, symbol:String):Void {
        if (Types.isNullable(value.type)) {
            fail("nullable-operand",
                '${Types.print(value.type)} may be null, so ${symbol} cannot use it',
                value.position, nullHint);
        }
        if (!Types.isNumber(value.type)) {
            var hint = value.type == TString ? "Compose text with interpolation" : null;
            fail("arithmetic-type", '${symbol} needs numbers but got ${Types.print(value.type)}',
                value.position, hint);
        }
    }

    function requireOrdered(value:TypedExpr, symbol:String):Void {
        if (Types.isNullable(value.type)) {
            fail("nullable-operand",
                '${Types.print(value.type)} may be null, so ${symbol} cannot use it',
                value.position, nullHint);
        }
        if (!Types.isNumber(value.type) && value.type != TString && value.type != TDate) {
            fail("comparison-type",
                '${symbol} orders numbers, strings and dates but got ${Types.print(value.type)}',
                value.position);
        }
    }

    static function cannotCompare(left:TypedExpr, right:TypedExpr):String {
        return 'Cannot compare ${Types.print(left.type)} with ${Types.print(right.type)}';
    }

    static function pairText(left:TypedExpr, right:TypedExpr):String {
        return '${Types.print(left.type)} and ${Types.print(right.type)}';
    }

    static function nullableHint(value:WellType, expected:WellType):Null<String> {
        return Types.isNullable(value) && !Types.isNullable(expected) ? nullHint : null;
    }

    static function operatorSymbol(operation:BinaryOperator):String {
        return switch operation {
            case Add: "+";
            case Subtract: "-";
            case Multiply: "*";
            case Divide: "/";
            case Modulo: "%";
            case Less: "<";
            case LessOrEqual: "<=";
            case Greater: ">";
            case GreaterOrEqual: ">=";
            default: Std.string(operation);
        }
    }

    static function findField(fields:Array<FieldInfo>, name:String):Null<FieldInfo> {
        for (field in fields) {
            if (field.name == name) {
                return field;
            }
        }
        return null;
    }

    static function findParameter(parameters:Array<Parameter>, name:String):Null<Parameter> {
        for (parameter in parameters) {
            if (parameter.name == name) {
                return parameter;
            }
        }
        return null;
    }

    inline function typed(kind:TypedKind, type:WellType, position:Position):TypedExpr {
        return new TypedExpr(kind, type, position);
    }

    function warn(code:String, message:String, position:Position, ?hint:String):Void {
        diagnostics.push(new Diagnostic(code, message, position, hint, Warning));
    }

    function fail(code:String, message:String, position:Position, ?hint:String):Dynamic {
        diagnostics.push(new Diagnostic(code, message, position, hint));
        throw new CheckFailure();
    }
}
