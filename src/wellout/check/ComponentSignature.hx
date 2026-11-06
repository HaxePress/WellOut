package wellout.check;

import wellout.check.Types;

/** A prop a component accepts (SPEC §5.1). */
class PropSignature {
    public final name:String;
    public final type:WellType;

    /** Required when the prop has no default and is not nullable. **/
    public final required:Bool;

    public function new(name:String, type:WellType, required:Bool) {
        this.name = name;
        this.type = type;
        this.required = required;
    }
}

/** A slot a component renders (§5.3); `exposes` is the value it passes to `:let`, if any. */
class SlotSignature {
    public final name:String;
    public final exposes:Null<WellType>;

    public function new(name:String, ?exposes:WellType) {
        this.name = name;
        this.exposes = exposes;
    }
}

/** How a template looks to its callers: its props, slots and whether it forwards attributes. */
class ComponentSignature {
    public static inline final DEFAULT_SLOT = "default";

    public final name:String;
    public final props:Array<PropSignature>;
    public final slots:Array<SlotSignature>;

    /** Whether an element carries `:attrs`, so callers may pass class, id, aria-* and data-*. **/
    public final acceptsAttributes:Bool;

    /** True while the component is still being checked, which a call inside itself hits. **/
    public final incomplete:Bool;

    public function new(name:String, props:Array<PropSignature>, slots:Array<SlotSignature>,
            acceptsAttributes:Bool, incomplete:Bool = false) {
        this.name = name;
        this.props = props;
        this.slots = slots;
        this.acceptsAttributes = acceptsAttributes;
        this.incomplete = incomplete;
    }

    public function prop(name:String):Null<PropSignature> {
        for (prop in props) {
            if (prop.name == name) {
                return prop;
            }
        }
        return null;
    }

    public function slot(name:String):Null<SlotSignature> {
        for (slot in slots) {
            if (slot.name == name) {
                return slot;
            }
        }
        return null;
    }

    public function propNames():Array<String> {
        return [for (prop in props) prop.name];
    }

    public function slotNames():Array<String> {
        return [for (slot in slots) slot.name];
    }
}

/** Resolves component names for a template, following the host's lookup chain (§5.5). */
interface ComponentResolver {
    /** The signature of a component, or null when it is unknown or fails to check. **/
    function resolve(name:String):Null<ComponentSignature>;

    /** Whether a component with this name exists, even if it fails to check. **/
    function has(name:String):Bool;

    function names():Array<String>;
}
