import wellout.SafeHtml;
import wellout.Url;
import wellout.check.HostContract;
import wellout.check.Types;
import wellout.macro.ViewSchema;

typedef TagView = {
    var name:String;
    var url:Url;
}

typedef CardView = {
    var title:String;
    @:optional var excerpt:String;
    var image:Null<Url>;
    var tags:Array<TagView>;
    var meta:Map<String, String>;
    @:well.requires("team.view") var author:String;
    @:well.private var secret:String;
    var body:SafeHtml;
    var count:Int;
    var ratio:Float;
    var featured:Bool;
    var related:Array<CardView>;
}

class SchemaTest {
    public static function run(check:(Bool, String) -> Void):Void {
        var contract = ViewSchema.register(new HostContract(), CardView);
        var card = contract.viewType("CardView");
        check(card != null && contract.viewType("TagView") != null,
            "typedefs and the typedefs they reference become view types");
        if (card == null) {
            return;
        }
        var expected = [
            "title" => "String",
            "excerpt" => "String?",
            "image" => "Url?",
            "tags" => "List<TagView>",
            "meta" => "Map<String, String>",
            "author" => "String",
            "body" => "SafeHtml",
            "count" => "Int",
            "ratio" => "Float",
            "featured" => "Bool",
            "related" => "List<CardView>"
        ];
        for (name => type in expected) {
            var field = card.field(name);
            var printed = field == null ? "missing" : Types.print(field.type);
            check(printed == type, 'field ${name} is ${type} (got ${printed})');
        }
        check(card.field("secret") == null, "private fields are hidden");
        check(card.field("author").requires == "team.view", "capability tags are kept");
        var scanned = ViewSchema.registerPackage(new HostContract(), "views");
        check(scanned.viewType("BadgeView") != null && scanned.viewType("BadgeTone") != null
            && scanned.viewType("UnusedView") == null,
            "registerPackage finds marked typedefs and the types they reference");
    }
}
