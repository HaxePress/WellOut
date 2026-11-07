package wellout.render;

/**
    Keeps the images of compiled templates between processes (see
    `TemplateImage`). A set asks its store before it parses, checks and
    compiles a template, and saves the image of each template it compiles.
    A store holds the templates of one set version: the host keys it by the
    template sources and the image format, so a stored image never outlives
    the sources it was compiled from.
**/
interface TemplateStore {
    /** The stored image of `name`, or null. **/
    function load(name:String):Null<Dynamic>;

    /** Stores the image of `name`; a store may also ignore it. **/
    function save(name:String, image:Array<Dynamic>):Void;
}
