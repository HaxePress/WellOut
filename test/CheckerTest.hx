import wellout.Result;
import wellout.check.ConditionFacts;
import wellout.check.ExpressionChecker;
import wellout.check.HostContract;
import wellout.check.Scope;
import wellout.check.TypedExpr;
import wellout.check.Types;
import wellout.syntax.Diagnostic;
import wellout.syntax.ExpressionParser;

class CheckerTest {
    static var check:(Bool, String) -> Void;
    static var contract:HostContract;
    static var scope:Scope;

    public static function run(assert:(Bool, String) -> Void):Void {
        check = assert;
        contract = buildContract();
        scope = buildScope();
        typesNamesAndRoots();
        typesFieldsAndIndexes();
        narrowsTestedPaths();
        typesHelperCalls();
        typesFilters();
        typesArithmetic();
        typesComparisons();
        typesLogicAndCoalesce();
        typesConditionalsAndCollections();
        warnsAboutGuardedFields();
        resolvesDeclaredTypes();
        buildsTypedTrees();
        collectsConditionFacts();
    }

    static function buildContract():HostContract {
        var contract = new HostContract();
        contract.addView(new RecordType("Tag",
            [field("id", TInt), field("name", TString), field("url", TUrl)]));
        contract.addView(new RecordType("ContentSummary", [
            field("title", TString),
            field("url", TUrl),
            field("excerpt", TNullable(TString)),
            field("image", TNullable(TUrl)),
            field("image_alt", TNullable(TString)),
            field("published_at", TNullable(TDate)),
            field("tags", TList(TView("Tag"))),
            field("read_minutes", TInt),
            new FieldInfo("author_name", TString, "team.view"),
            field("meta", TMap(TString))
        ]));
        contract.addView(new RecordType("Site",
            [field("site_name", TString), field("tagline", TNullable(TString))]));
        contract.addView(new RecordType("Locale", [field("code", TString), field("dir", TString)]));
        contract.addRoot("site", TView("Site"));
        contract.addRoot("locale", TView("Locale"));
        contract.addRoot("csrf", TString);
        contract.addHelper(new HelperSignature("t", [required("key", TString)], TString, true));
        contract.addHelper(new HelperSignature("route", [required("name", TString)], TUrl, true));
        contract.addHelper(new HelperSignature("asset", [required("path", TString)], TUrl));
        contract.addHelper(new HelperSignature("can", [required("capability", TString)], TBool));
        contract.addHelper(new HelperSignature("old", [required("field", TString)],
            TNullable(TString)));
        contract.addHelper(new HelperSignature("first",
            [required("list", TList(TParameter("T")))], TNullable(TParameter("T"))));
        return contract;
    }

    static function buildScope():Scope {
        var scope = new Scope();
        scope.bind("post", Prop, TView("ContentSummary"));
        scope.bind("optional", Prop, TNullable(TView("ContentSummary")));
        scope.bind("featured", Prop, TBool);
        scope.bind("count", Prop, TInt);
        scope.bind("ratio", Prop, TFloat);
        scope.bind("name", Prop, TString);
        scope.bind("names", Prop, TList(TString));
        scope.bind("items", Prop, TList(TView("ContentSummary")));
        scope.bind("travel", Source, TList(TView("ContentSummary")));
        scope.bind("tag", Variable, TView("Tag"));
        scope.bind("loop", Loop, TView("Loop"));
        return scope;
    }

    static function field(name:String, type:WellType):FieldInfo {
        return new FieldInfo(name, type);
    }

    static function required(name:String, type:WellType):Parameter {
        return new Parameter(name, type);
    }

    static function checked(source:String, ?inScope:Scope):Result<TypedExpr> {
        var parsed = ExpressionParser.parse(source);
        if (parsed.value == null) {
            return new Result(null, parsed.diagnostics);
        }
        return ExpressionChecker.check(parsed.value, inScope == null ? scope : inScope, contract);
    }

    static function typeOf(source:String, ?inScope:Scope):String {
        var result = checked(source, inScope);
        if (result.value == null) {
            return 'error ${result.diagnostics[0].code}';
        }
        return Types.print(result.value.type);
    }

    static function expectType(source:String, expected:String, ?inScope:Scope):Void {
        var got = typeOf(source, inScope);
        check(got == expected, '${source}: expected ${expected}, got ${got}');
    }

    static function expectError(source:String, code:String, column:Int,
            ?hintPart:String):Null<Diagnostic> {
        var result = checked(source);
        var errors = result.diagnostics.filter(diagnostic -> diagnostic.isError());
        var summary = [for (diagnostic in errors) '${diagnostic.code}@${diagnostic.position}'];
        check(result.value == null && errors.length == 1 && errors[0].code == code,
            '${source}: expected ${code} (got ${summary.join(", ")})');
        if (errors.length == 0) {
            return null;
        }
        var error = errors[0];
        check(error.position.line == 1 && error.position.column == column,
            '${source}: expected ${code} at column ${column}, got ${error.position}');
        if (hintPart != null) {
            check(error.hint != null && error.hint.indexOf(hintPart) >= 0,
                '${source}: expected a hint mentioning ${hintPart}, got ${error.hint}');
        }
        return error;
    }

    static function typesNamesAndRoots():Void {
        expectType("post", "ContentSummary");
        expectType("optional", "ContentSummary?");
        expectType("travel", "List<ContentSummary>");
        expectType("tag", "Tag");
        expectType("site.site_name", "String");
        expectType("site.tagline", "String?");
        expectType("csrf", "String");
        expectType("loop.index", "Int");
        expectType("loop.parent.index", "Int?");
        expectType("'text'", "String");
        expectType("1.5", "Float");
        expectType("null", "null");
        expectError("unknown", "unknown-name", 1);
        expectError("psot.title", "unknown-name", 1, "Did you mean post?");
        expectError("sit.site_name", "unknown-name", 1, "Did you mean site?");
    }

    static function typesFieldsAndIndexes():Void {
        expectType("post.title", "String");
        expectType("post.excerpt", "String?");
        expectType("post.tags", "List<Tag>");
        expectType("post.tags[0]", "Tag?");
        expectType("post.tags[0].name", "String?");
        expectType("post.tags[count].url", "Url?");
        expectType("post.meta['og:title']", "String?");
        expectType("post.meta[name]", "String?");
        expectType("optional.title", "String?");
        expectType("optional.excerpt", "String?");
        expectType("items[1].tags", "List<Tag>?");
        expectError("post.titel", "unknown-field", 6, "Did you mean title?");
        expectError("post.title.length", "no-fields", 12);
        expectError("post.title[0]", "not-indexable", 11);
        expectError("post.tags['x']", "index-type", 11);
        expectError("post.tags[ratio]", "index-type", 11);
        expectError("post.meta[0]", "index-type", 11);
        expectError("post.tags[optional.read_minutes]", "index-type", 11);
    }

    static function narrowsTestedPaths():Void {
        expectType("optional ? optional.title : 'none'", "String");
        expectType("optional != null ? optional.title : 'none'", "String");
        expectType("post.excerpt ? post.excerpt : 'none'", "String");
        expectType("post.excerpt and post.excerpt", "Bool");
        expectType("featured ? optional.title : 'none'", "String?");
        expectType("optional.excerpt ? optional.title : 'none'", "String");
        expectType("not optional ? optional.title : 'none'", "String?");
        expectType("optional or featured ? optional.title : 'none'", "String?");
        var narrowed = scope.child().narrow("post.excerpt");
        expectType("post.excerpt", "String", narrowed);
        expectType("post.excerpt | truncate(5)", "String", narrowed);
        expectType("post.title", "String", narrowed);
        var deeper = scope.child().narrow("optional.excerpt");
        expectType("optional.excerpt", "String", deeper);
        expectType("optional.title", "String?", deeper);
    }

    static function typesHelperCalls():Void {
        expectType("t('Subscribe')", "String");
        expectType("t('x', count: count, name: name)", "String");
        expectType("route('home', page: 2)", "Url");
        expectType("asset('app.css')", "Url");
        expectType("asset(path: 'app.css')", "Url");
        expectType("can('publish')", "Bool");
        expectType("old('email')", "String?");
        expectType("first(items)", "ContentSummary?");
        expectType("first(names)", "String?");
        expectType("first([1, 2])", "Int?");
        expectError("t()", "missing-argument", 1);
        expectError("t(1)", "argument-type", 3);
        expectError("t(post.excerpt)", "argument-type", 3, "??");
        expectError("asset('a', 'b')", "too-many-arguments", 12);
        expectError("asset(pat: 'a')", "unknown-argument", 7, "Did you mean path?");
        expectError("asset('a', path: 'b')", "duplicate-argument", 12);
        expectError("nope('x')", "unknown-helper", 1);
        expectError("rout('x')", "unknown-helper", 1, "Did you mean route?");
        expectError("first(post)", "argument-type", 7);
    }

    static function typesFilters():Void {
        expectType("post.title | upper", "String");
        expectType("post.title | truncate(10)", "String");
        expectType("post.excerpt | truncate(10)", "String?");
        expectType("post.excerpt | default('none')", "String");
        expectType("optional.excerpt | default(name)", "String");
        expectType("post.published_at | date('long')", "String?");
        expectType("post.published_at | date", "String?");
        expectType("count | number", "String");
        expectType("ratio | number('percent')", "String");
        expectType("post.excerpt | truncate(10) | upper", "String?");
        expectType("post.excerpt | default('') | upper", "String");
        expectError("count | upper", "filter-input", 9);
        expectError("post.title | truncat(3)", "unknown-filter", 14, "Did you mean truncate?");
        expectError("post.title | truncate", "missing-argument", 14);
        expectError("post.title | truncate('x')", "argument-type", 23);
        expectError("post.title | lower('x')", "too-many-arguments", 20);
        expectError("post.excerpt | default(5)", "argument-type", 24);
    }

    static function typesArithmetic():Void {
        expectType("count + 1", "Int");
        expectType("count + ratio", "Float");
        expectType("count / 2", "Float");
        expectType("count % 2", "Int");
        expectType("-count", "Int");
        expectType("-ratio", "Float");
        expectType("post.read_minutes * 60", "Int");
        expectType("loop.index + 1", "Int");
        expectError("count + name", "arithmetic-type", 9, "interpolation");
        expectError("name + 'x'", "arithmetic-type", 1);
        expectError("optional.read_minutes + 1", "nullable-operand", 1, "??");
        expectError("-featured", "arithmetic-type", 2);
    }

    static function typesComparisons():Void {
        expectType("count == 1", "Bool");
        expectType("count != ratio", "Bool");
        expectType("name == 'x'", "Bool");
        expectType("post.excerpt == null", "Bool");
        expectType("null != post.excerpt", "Bool");
        expectType("optional == post", "Bool");
        expectType("count < ratio", "Bool");
        expectType("name < 'b'", "Bool");
        expectType("featured == true", "Bool");
        expectError("name == 1", "comparison-type", 6);
        expectError("post == tag", "comparison-type", 6);
        expectError("name < count", "comparison-type", 6);
        expectError("post.published_at < post.published_at", "nullable-operand", 1);
        expectError("featured < true", "comparison-type", 1);
    }

    static function typesLogicAndCoalesce():Void {
        expectType("tag in post.tags", "Bool");
        expectType("name in names", "Bool");
        expectType("post.excerpt in names", "Bool");
        expectType("count in [1, 2]", "Bool");
        expectType("not post", "Bool");
        expectType("post.excerpt and featured", "Bool");
        expectType("name or count", "Bool");
        expectType("post.excerpt ?? 'none'", "String");
        expectType("optional.excerpt ?? post.excerpt", "String?");
        expectType("post.excerpt ?? site.tagline ?? 'none'", "String");
        expectType("first(names) ?? name", "String");
        expectError("count in names", "membership-type", 7);
        expectError("name in post", "membership-type", 6);
        expectError("post.excerpt ?? count", "coalesce-type", 14);
    }

    static function typesConditionalsAndCollections():Void {
        expectType("featured ? 'a' : 'b'", "String");
        expectType("featured ? 'a'", "String?");
        expectType("featured ? count : ratio", "Float");
        expectType("featured ? 'a' : null", "String?");
        expectType("featured ? post.excerpt : 'b'", "String?");
        expectType("featured ? [] : names", "List<String>");
        expectType("[1, 2]", "List<Int>");
        expectType("[1, ratio]", "List<Float>");
        expectType("[]", "List<unknown>");
        expectType("['a', post.excerpt]", "List<String?>");
        expectType("[post, optional]", "List<ContentSummary?>");
        expectType("{ list: 'main', count: count }", "{ list: String, count: Int }");
        expectType("{}", "{}");
        expectType("featured ? { a: 1 } : { a: ratio }", "{ a: Float }");
        expectError("featured ? 'a' : 1", "branch-type", 18);
        expectError("['a', 1]", "list-item-type", 7);
        expectError("featured ? { a: 1 } : { b: 1 }", "branch-type", 23);
    }

    static function warnsAboutGuardedFields():Void {
        var unguarded = checked("post.author_name");
        check(unguarded.value != null && Types.print(unguarded.value.type) == "String",
            "a guarded field still has its type");
        check(!unguarded.hasErrors()
            && unguarded.diagnostics.length == 1
            && unguarded.diagnostics[0].code == "unguarded-field"
            && unguarded.diagnostics[0].position.column == 6,
            "reading a guarded field outside can() warns");
        var guarded = checked("can('team.view') and post.author_name");
        check(guarded.diagnostics.length == 0,
            "a can() guard in an and chain silences the warning");
        var branch = checked("can('team.view') ? post.author_name : ''");
        check(branch.diagnostics.length == 0, "a can() condition guards the consequent");
        var other = checked("can('other') and post.author_name");
        check(other.diagnostics.length == 1, "a different capability does not guard the field");
        var scoped = checked("post.author_name", scope.child().guard("team.view"));
        check(scoped.diagnostics.length == 0, "a guard recorded on the scope silences the warning");
        var formatted = unguarded.diagnostics[0].format("post.author_name", "card.well.html");
        check(StringTools.startsWith(formatted, "card.well.html:1:6: warning: "),
            'warnings are labelled when formatted (got ${formatted.split("\n")[0]})');
    }

    static function resolvesDeclaredTypes():Void {
        var sources = [
            "String",
            "ContentSummary",
            "List<ContentSummary>?",
            "Map<String, Int>",
            "Map<String, List<Tag>>",
            "Loop"
        ];
        for (source in sources) {
            var diagnostics:Array<Diagnostic> = [];
            var syntax = ExpressionParser.parseType(source).value;
            var resolved = Types.resolve(syntax, contract, diagnostics);
            var printed = resolved == null ? "null" : Types.print(resolved);
            check(resolved != null && printed == source && diagnostics.length == 0,
                'type ${source} resolves (got ${printed})');
        }
        expectTypeError("ContentSumary", "unknown-type", 1, "Did you mean ContentSummary?");
        expectTypeError("Strin", "unknown-type", 1, "Did you mean String?");
        expectTypeError("Map<Int, String>", "map-key-type", 5);
        expectTypeError("List<A, B>", "type-parameters", 1);
        expectTypeError("String<Int>", "type-parameters", 1);
        expectTypeError("List<Nope>", "unknown-type", 6);
    }

    static function expectTypeError(source:String, code:String, column:Int, ?hintPart:String):Void {
        var diagnostics:Array<Diagnostic> = [];
        var syntax = ExpressionParser.parseType(source).value;
        var resolved = syntax == null ? null : Types.resolve(syntax, contract, diagnostics);
        var summary = [for (diagnostic in diagnostics) '${diagnostic.code}@${diagnostic.position}'];
        check(resolved == null
            && diagnostics.length == 1
            && diagnostics[0].code == code
            && diagnostics[0].position.column == column,
            '${source}: expected ${code} at column ${column} (got ${summary.join(", ")})');
        if (hintPart != null && diagnostics.length == 1) {
            check(diagnostics[0].hint != null && diagnostics[0].hint.indexOf(hintPart) >= 0,
                '${source}: expected a hint mentioning ${hintPart}, got ${diagnostics[0].hint}');
        }
    }

    static function buildsTypedTrees():Void {
        check(shape(checked("post.tags[0].name").value) == "post:Prop.tags[const]?.name",
            "a path becomes nested name, field and index nodes");
        check(shape(checked("optional.title").value) == "optional:Prop?.title",
            "a field read on a nullable target is marked null-safe");
        var narrowed = checked("optional.title", scope.child().narrow("optional")).value;
        check(shape(narrowed) == "optional:Prop.title", "narrowing removes the null-safe read");
        check(shape(checked("site.site_name").value) == "root site.site_name",
            "implicit roots are resolved separately");
        check(shape(checked("post.excerpt | truncate(3)").value) == "post:Prop.excerpt|truncate",
            "filters keep their target and signature");
        check(shape(checked("t('x', count: count)").value) == "t(key, count)",
            "call arguments are matched to parameters");
        check(shape(checked("tag in post.tags").value) == "(tag:Variable In post:Prop.tags)",
            "operators keep their operation");
    }

    static function shape(typed:Null<TypedExpr>):String {
        if (typed == null) {
            return "null";
        }
        return switch typed.kind {
            case Constant(_):
                "const";
            case Name(name, binding):
                '${name}:${binding}';
            case Root(name):
                'root ${name}';
            case FieldAccess(target, _, field):
                var separator = Types.isNullable(target.type) ? "?." : ".";
                '${shape(target)}${separator}${field.name}';
            case IndexAccess(target, key):
                '${shape(target)}[${shape(key)}]';
            case HelperCall(helper, arguments):
                var names = [
                    for (argument in arguments)
                        argument.parameter == null ? argument.name : argument.parameter.name
                ];
                '${helper.name}(${names.join(", ")})';
            case FilterCall(target, filter, _):
                '${shape(target)}|${filter.name}';
            case BinaryOp(operation, left, right):
                '(${shape(left)} ${operation} ${shape(right)})';
            default:
                "other";
        }
    }

    static function collectsConditionFacts():Void {
        var condition = "post.tags[0].url and can('x') and optional != null";
        var facts = ConditionFacts.of(ExpressionParser.parse(condition).value);
        var paths = facts.nonNullPaths.join(" ");
        check(paths == "post post.tags post.tags[0] post.tags[0].url optional",
            'facts narrow every prefix (got ${paths})');
        check(facts.capabilities.join(" ") == "x", "facts record can() capabilities");
        var computed = ConditionFacts.of(ExpressionParser.parse("post.meta[name]").value);
        check(computed.nonNullPaths.join(" ") == "post post.meta",
            'a computed index stops the path key (got ${computed.nonNullPaths.join(" ")})');
        var negated = ConditionFacts.of(ExpressionParser.parse("not post.excerpt or featured")
            .value);
        check(negated.nonNullPaths.length == 0 && negated.capabilities.length == 0,
            "not and or establish nothing");
    }
}
