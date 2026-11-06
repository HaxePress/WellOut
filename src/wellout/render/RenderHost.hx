package wellout.render;

import wellout.check.CheckedTemplate.AssetKind;

/**
    What a render needs from the host for one response (SPEC §2). Helpers
    and sources reach request state through `RenderContext.host`, cast to
    the host's own class.
**/
interface RenderHost {
    /** The value of an implicit root such as `site` (§5.6). **/
    function root(name:String):Dynamic;

    /**
        Maps site-relative URLs, such as `/content`, before they are written,
        for example to keep links inside a theme preview (§8.2). Null leaves
        them unchanged, which costs nothing per link.
    **/
    function linkMapper():Null<String->String>;

    /** The CSRF token added to post forms (§8.5). **/
    function csrfToken():String;

    /** The response's CSP nonce, carried by system scripts and island props (§11). **/
    function nonce():String;

    /** The public URL of an asset declared with `<Asset>`. **/
    function assetUrl(kind:AssetKind, path:String):String;

    /** The module URL of an island (§9.3). **/
    function islandModule(name:String):String;

    /** A translated message for island catalogues (§10). **/
    function translate(key:String):String;

    /** The URL of the Wellout client runtime, loaded when a page swaps or has islands (§9.4). **/
    function runtimeScript():String;
}
