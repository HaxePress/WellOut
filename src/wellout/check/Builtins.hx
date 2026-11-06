package wellout.check;

import wellout.check.Types;

/** The language's own entries in every host contract: built-in filters and `loop` metadata. */
class Builtins {
    public static function install(contract:HostContract):Void {
        contract.addView(new RecordType("Loop", [
            new FieldInfo("index", TInt),
            new FieldInfo("number", TInt),
            new FieldInfo("first", TBool),
            new FieldInfo("last", TBool),
            new FieldInfo("length", TInt),
            new FieldInfo("parent", TNullable(TView("Loop")))
        ]));
        var style = new Parameter("style", TString, true);
        contract.addFilter(new FilterSignature("date", TDate, [style], TString));
        contract.addFilter(new FilterSignature("number", TFloat, [style], TString));
        contract.addFilter(new FilterSignature("truncate", TString,
            [new Parameter("length", TInt)], TString));
        contract.addFilter(new FilterSignature("lower", TString, [], TString));
        contract.addFilter(new FilterSignature("upper", TString, [], TString));
        contract.addFilter(new FilterSignature("default", TNullable(TParameter("T")),
            [new Parameter("value", TParameter("T"))], TParameter("T")));
        contract.addFilter(new FilterSignature("color", TString, [], TString));
        contract.addFilter(new FilterSignature("length", TString, [], TString));
    }
}
