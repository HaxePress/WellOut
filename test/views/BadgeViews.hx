package views;

@:well.view
typedef BadgeView = {
    var label:String;
    var tone:BadgeTone;
}

typedef BadgeTone = {
    var name:String;
}

/** Not marked, so it is registered only when a view references it. */
typedef UnusedView = {
    var ignored:String;
}
