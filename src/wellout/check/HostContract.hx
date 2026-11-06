package wellout.check;

import wellout.check.Types;

/**
    What a host exposes to templates (SPEC §6.3): view types, helpers,
    filters, sources, islands and implicit roots. A new contract already
    holds the built-in filters and the `Loop` view type; the host adds its
    own entries.
**/
class HostContract {
    final views:Map<String, RecordType> = [];
    final helpers:Map<String, HelperSignature> = [];
    final filters:Map<String, FilterSignature> = [];
    final sources:Map<String, SourceSignature> = [];
    final islands:Map<String, IslandSignature> = [];
    final roots:Map<String, WellType> = [];
    final viewOrder:Array<String> = [];
    final helperOrder:Array<String> = [];
    final filterOrder:Array<String> = [];
    final sourceOrder:Array<String> = [];
    final islandOrder:Array<String> = [];
    final rootOrder:Array<String> = [];

    public function new() {
        Builtins.install(this);
    }

    public function addView(view:RecordType):HostContract {
        if (!views.exists(view.name)) {
            viewOrder.push(view.name);
        }
        views.set(view.name, view);
        return this;
    }

    public function addHelper(helper:HelperSignature):HostContract {
        if (!helpers.exists(helper.name)) {
            helperOrder.push(helper.name);
        }
        helpers.set(helper.name, helper);
        return this;
    }

    public function addFilter(filter:FilterSignature):HostContract {
        if (!filters.exists(filter.name)) {
            filterOrder.push(filter.name);
        }
        filters.set(filter.name, filter);
        return this;
    }

    public function addSource(source:SourceSignature):HostContract {
        if (!sources.exists(source.name)) {
            sourceOrder.push(source.name);
        }
        sources.set(source.name, source);
        return this;
    }

    public function addIsland(island:IslandSignature):HostContract {
        if (!islands.exists(island.name)) {
            islandOrder.push(island.name);
        }
        islands.set(island.name, island);
        return this;
    }

    /** Declares an implicit root such as `site` (§5.6). **/
    public function addRoot(name:String, type:WellType):HostContract {
        if (!roots.exists(name)) {
            rootOrder.push(name);
        }
        roots.set(name, type);
        return this;
    }

    public function viewType(name:String):Null<RecordType> {
        return views.get(name);
    }

    public function helper(name:String):Null<HelperSignature> {
        return helpers.get(name);
    }

    public function filter(name:String):Null<FilterSignature> {
        return filters.get(name);
    }

    public function source(name:String):Null<SourceSignature> {
        return sources.get(name);
    }

    public function island(name:String):Null<IslandSignature> {
        return islands.get(name);
    }

    public function root(name:String):Null<WellType> {
        return roots.get(name);
    }

    public function viewNames():Array<String> {
        return viewOrder.copy();
    }

    public function helperNames():Array<String> {
        return helperOrder.copy();
    }

    public function filterNames():Array<String> {
        return filterOrder.copy();
    }

    public function sourceNames():Array<String> {
        return sourceOrder.copy();
    }

    public function islandNames():Array<String> {
        return islandOrder.copy();
    }

    public function rootNames():Array<String> {
        return rootOrder.copy();
    }
}
