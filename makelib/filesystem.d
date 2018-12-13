module makelib.filesystem;

import std.typecons : Flag, Yes, No;
import traits = std.traits;
import std.bitmanip : bitfields;
import std.algorithm : count, canFind, findAmong, equal;
import std.format : formattedWrite;
import std.datetime : SysTime;
import path = std.path;
import io = std.stdio;
static import std.file;

import makelib.engine : TimestampTag, Make;
import makelib.filepatterns : validPatternNameChar, namedPattern, targetMatchPattern;

struct Timestamp
{
    private SysTime sysTime = void;
    TimestampTag tag;
    this(TimestampTag tag) { this.tag = tag; }
    this(TimestampTag tag, SysTime sysTime) { this.tag = tag; this.sysTime = sysTime; }
    final void toString(scope void delegate(const(char)[]) sink)
    {
        final switch(tag)
        {
            case TimestampTag.notMade : sink("notMade"); return;
            case TimestampTag.preMadeNoTime : sink("preMadeNoTime"); return;
            case TimestampTag.preMadeWithTime : formattedWrite(sink, "%s", sysTime); return;
            case TimestampTag.newlyMade : sink("newlyMade"); return;
        }
    }

    @property static Timestamp notMade()         { return Timestamp(TimestampTag.notMade); }
    @property static Timestamp preMadeNoTime()   { return Timestamp(TimestampTag.preMadeNoTime); }
    @property static Timestamp newlyMade()       { return Timestamp(TimestampTag.newlyMade); }

    static Timestamp preMadeWithTime(SysTime time) { return Timestamp(TimestampTag.preMadeWithTime, time); }

    auto opCmp(const(Timestamp) right) const
    {
        final switch(tag) with(TimestampTag)
        {
            case notMade: return (right.tag == notMade) ? 0 : -1;
            case preMadeNoTime:
                if(right.tag == notMade) return 1;
                if(right.tag == preMadeNoTime) return 0;
                return -1;
            case preMadeWithTime:
                if(right.tag < preMadeWithTime) return 1;
                if(right.tag == preMadeWithTime)
                    return this.sysTime.opCmp(right.sysTime);
                return -1;
            case newlyMade:  return (right.tag == newlyMade) ? 0 : 1;
        }
    }
}

abstract class Item
{
    private static FileName[string] nameTable;
    static FileName getGlobalItem(string name)
    {
        auto normalized = path.buildNormalizedPath(name);
        auto entry = nameTable.get(normalized, null);
        if(entry is null)
        {
            entry = new FileName(normalized);
            nameTable[normalized] = entry;
        }
        return entry;
    }

    @property abstract string getName();

    // Make Engine Functions
    abstract void notifyBuilt();
    abstract Timestamp getTimestamp();
    final Timestamp getTimestampNoRule()
    {
        return getTimestamp();
    }
    abstract Timestamp getTimestampIfAlreadyBuilt();
}
class FileName : Item
{
    enum State : ubyte
    {
        initial,
        doesNotExist,
        isDir,
        isNotDir,
        built,
    }

    string name;
    private Timestamp builtTimestamp;
    State state;

    this(string name) { this.name = name; }
    @property override string getName() { return name; }
    override string toString() const { return name; }
    //
    // Make Engine Functions
    //
    override void notifyBuilt()
    {
        assert(state != State.initial && state != State.isDir);
        state = State.built;
    }
    override Timestamp getTimestamp()
    {
        //import std.stdio; writefln("[DEBUG] getTimestamp '%s'", name);
        final switch(state)
        {
        case State.initial:
            version(Windows)
            {{
                import std.internal.cstring : tempCString;
                import core.sys.windows.windows : GetFileAttributesA, INVALID_FILE_ATTRIBUTES;
                auto attributes = GetFileAttributesA(name.tempCString);
                //import std.stdio; writefln("[DEBUG] getTimestamp '%s' (attributes = 0x%x)", name, attributes);
                if(attributes == INVALID_FILE_ATTRIBUTES)
                {
                    state = State.doesNotExist;
                    goto case State.doesNotExist;
                }
                if(attributes & 0x10)
                {
                    state = State.isDir;
                    goto case State.isDir;
                }
                state = State.isNotDir;
                goto case State.isNotDir;
            }}
            else
            {{
                import std.internal.cstring : tempCString;
                import core.sys.posix.sys.stat : stat_t, stat, S_ISDIR;
                stat_t statbuf = void;
                auto result = stat(name.tempCString, &statbuf);
                if (result == -1)
                {
                    state = State.doesNotExist;
                    goto case State.doesNotExist;
                }
                if (S_ISDIR(statbuf.st_mode))
                {
                    state = State.isDir;
                    goto case State.isDir;
                }
                state = State.isNotDir;
                goto case State.isNotDir;
            }}
        case State.doesNotExist: return Timestamp.notMade;
        case State.isDir:
            //import std.stdio; writefln("[DEBUG] getTimestamp '%s' (IS DIR)", name);
            return Timestamp.preMadeNoTime;
        case State.isNotDir:
            auto result = Timestamp.preMadeWithTime(std.file.timeLastModified(name));
            //import std.stdio; writefln("[DEBUG] getTimestamp '%s' %s", name, result.sysTime);
            return result;
        /*
            auto result = std.file.timeLastModified(name, SysTime.min);
            if(result == SysTime.min)
            {
                import std.stdio; writefln("[DEBUG] getTimestamp '%s' (NOT MADE)", name);
                return Timestamp.notMade;
            }
            import std.stdio; writefln("[DEBUG] getTimestamp '%s' (IS MADE %s)", name, result);
            return Timestamp.preMadeWithTime(result);
            */
        case State.built: return Timestamp.newlyMade;
        }
    }
    override Timestamp getTimestampIfAlreadyBuilt()
    {
        final switch(state)
        {
        case State.initial: return Timestamp.notMade;
        case State.doesNotExist: return Timestamp.notMade;
        case State.isDir: return Timestamp.preMadeNoTime;
        case State.isNotDir: return Timestamp.notMade;
        case State.built: return Timestamp.newlyMade;
        }
    }
}

union ItemSpecifierRangeData
{
    alias DirIteratorType = typeof(std.file.dirEntries("","",std.file.SpanMode.shallow));

    Flag!"done" done = void;
    Item resolvedPatternItem = void;
    static struct PatternGlobData
    {
        DirIteratorType dirIterator;
        //string resolvedSpecifier;
    }
    PatternGlobData patternGlob = void;

    this(Flag!"done" done) { this.done = done; }
    this(Item resolvedPatternItem) { this.resolvedPatternItem = resolvedPatternItem; }
    this(DirIteratorType dirIterator)
    {
        this.patternGlob.dirIterator = dirIterator;
    }
}

enum GlobChars = "*?[{";

abstract class ItemSpecifier
{
    static ItemSpecifier create(string str)
    {
        foreach(i, c; str)
        {
            if(c == '$')
            {
                auto isGlob = findAmong(str[i+1 .. $], GlobChars).length > 0;
                //import std.stdio; writefln("ItemSpecifier.create(\"%s\") pattern=%s, glob=%s", str, true, isGlob);
                return new StringItemSpecifier(str, null, Yes.isPattern, isGlob ? Yes.isGlob : No.isGlob);
            }
            if(canFind(GlobChars, c))
            {
                auto isPattern = canFind(str[i+1 .. $], '$');
                //import std.stdio; writefln("ItemSpecifier.create(\"%s\") pattern=%s, glob=%s", str, isPattern, true);
                return new StringItemSpecifier(str, null, isPattern ? Yes.isPattern : No.isPattern, Yes.isGlob);
            }
        }
        //import std.stdio; writefln("ItemSpecifier.create(\"%s\") pattern=%s, glob=%s", str, false, false);
        return new StringItemSpecifier(str, Item.getGlobalItem(str), No.isPattern, No.isGlob);
    }
    //
    // Make Engine Functions
    //
    abstract size_t getRangeDataSize();
    abstract void initItemRange(void* data, Target targetCause, Item itemCause);
    abstract bool empty(void* data);
    abstract Item front(void* data);
    abstract void popFront(void* data);
}
class StringItemSpecifier : ItemSpecifier
{
    string str;
    Item item;
    mixin(bitfields!(
        bool , "isPattern", 1,
        bool , "isGlob"   , 1,
        ubyte, ""         , 6));
    this(string str, Item item, Flag!"isPattern" isPattern, Flag!"isGlob" isGlob)
    {
        this.str       = str;
        this.item      = item;
        this.isPattern = isPattern;
        this.isGlob    = isGlob;
    }
    override string toString() const { return str; }

    //
    // Make Engine Functions
    //
    final override size_t getRangeDataSize()
    {
        // TODO: make sure this size is aligned properly
        static assert((ItemSpecifierRangeData.sizeof % ItemSpecifierRangeData.alignof) == 0, "aligned not implemented");
        return ItemSpecifierRangeData.sizeof;
    }
    final override void initItemRange(void* data, Target targetCause, Item itemCause)
    {
        // TODO: make sure this data is aligned properly
        if(item !is null)
        {
            *cast(ItemSpecifierRangeData*)data = ItemSpecifierRangeData(No.done);
            return;
        }

        string resolvedSpecifier;
        if(isPattern)
            resolvedSpecifier = resolvePattern(str, targetCause, itemCause);
        else
            resolvedSpecifier = str;

        if(!isGlob)
        {
            // TODO: it might be possible that the resolvedSpecifier could be
            //       a glob
            if(resolvedSpecifier.findAmong(GlobChars).length)
            {
                assert(0, "Error: a non-glob pattern resolved to a glob item (not implemented)!");
            }
            *cast(ItemSpecifierRangeData*)data = ItemSpecifierRangeData(Item.getGlobalItem(resolvedSpecifier));
            return;
        }

        //import std.stdio; writefln("[DEBUG] dir '%s', pattern '%s'",
        //    glob[0..dirLimit], glob[patternStart..$]);
        // TODO: I don't think the dir/pattern I'm giving works in all cases
        *cast(ItemSpecifierRangeData*)data = ItemSpecifierRangeData(
            std.file.dirEntries(".", resolvedSpecifier, std.file.SpanMode.shallow));
    }
    final override bool empty(void* data)
    {
        auto itemData = cast(ItemSpecifierRangeData*)data;

        if(item !is null) return itemData.done;
        if(!isGlob)
        {
            // TODO: if this was a pattern, it could have resolved to a glob!
            return itemData.resolvedPatternItem is null;
        }
        return itemData.patternGlob.dirIterator.empty;
    }
    final override Item front(void* data)
    {
        if(item !is null) return item;

        auto itemData = cast(ItemSpecifierRangeData*)data;
        if(!isGlob)
        {
            // TODO: if this was a pattern, it could have resolved to a glob!
            return itemData.resolvedPatternItem;
        }
        return Item.getGlobalItem(itemData.patternGlob.dirIterator.front.name);
    }
    final override void popFront(void* data)
    {
        auto itemData = cast(ItemSpecifierRangeData*)data;

        if(item !is null)
        {
            itemData.done = Yes.done;
        }
        else if(!isGlob)
        {
            // TODO: if this was a pattern, it could have resolved to a glob!
            itemData.resolvedPatternItem = null;
        }
        else
        {
            itemData.patternGlob.dirIterator.popFront();
        }
    }
}

class CustomItemRange(T) : ItemSpecifier
{
    T rangeInitializer;
    this(T rangeInitializer)
    {
        this.rangeInitializer = rangeInitializer;
    }
    final override size_t getRangeDataSize()
    {
        static assert((T.RangeType.sizeof % T.RangeType.alignof) == 0,
            "extra padding for alignment is not implemented");
        return T.RangeType.sizeof;
    }
    final override void initItemRange(void* data, Target targetCause, Item itemCause)
    {
        rangeInitializer.initRange(cast(T.RangeType*)data);
    }
    final override bool empty(void* data)
    {
        return (cast(T.RangeType*)data).empty;
    }
    final override Item front(void* data)
    {
        return (cast(T.RangeType*)data).front;
    }
    final override void popFront(void* data)
    {
        (cast(T.RangeType*)data).popFront;
    }
}
auto customItemRange(T)(T range)
{
    return new CustomItemRange!T(range);
}

string resolvePattern(const(char)[] pattern, Target target, Item item)
{
    import std.array : appender;
    auto resolved = appender!(char[]);

    size_t start = 0;
    size_t next = 0;
    for(; next < pattern.length; next++)
    {
        if(pattern[next] == '$')
        {
            resolved.put(pattern[start .. next]);
            next++;
            if(next >= pattern.length)
                assert(0, "invalid item specifier, cannot end with '$'");
            start = next;
            size_t nameEnd;
            for(;;)
            {
                auto c = pattern[next];
                if(!validPatternNameChar(c))
                {
                    nameEnd = next;
                    if(c == ';')
                    {
                        next++;
                    }
                    break;
                }
                next++;
                if(next >= pattern.length)
                {
                    nameEnd = next;
                    break;
                }
            }
            auto name = pattern[start .. nameEnd];
            auto resolvedValue = resolveName(name, target, item);
            resolved.put(resolvedValue);
            start = next;
            if(next >= pattern.length)
                break;
        }
    }
    //import std.stdio; writefln("start=%s, next=%s, pattern=%s", start, next, pattern);
    resolved.put(pattern[start .. next]);
    return cast(string)resolved.data;
}

string resolveName(const(char)[] name, Target target, Item item)
{
    static struct ValueSaver
    {
        const(char)[] nameToSave;
        string value;
    }
    static struct FilePatternPolicy
    {
        enum escapeChar = '$';
        alias OnMatchArgs = ValueSaver*;
        static Flag!"stop" onMatchedName(const(char)[] name, const(char)[] value, ValueSaver* valueSaver)
        {
            if(valueSaver.nameToSave == name)
            {
                valueSaver.value = cast(string)value;
                return Yes.stop;
            }
            return No.stop;
        }
    }
    auto valueSaver = ValueSaver(name);
    if(!namedPattern!FilePatternPolicy.match(target.toString(), item.getName, &valueSaver))
    {
        import std.stdio;
        writefln("Error: resolveName: target '%s' does not match item '%s'", target, item);
        assert(0);
    }
    if(valueSaver.value is null)
    {
        import std.stdio;
        writefln("Error: target '%s' has no definition for name $%s",
            target, name);
        assert(0);
    }
    return valueSaver.value;
}

struct MatchLevel
{
    private enum Tag : byte
    {
        noMatch,
        pattern,
        exact,
    }
    Tag tag;
    @property bool isMatch() { return tag != Tag.noMatch; }
    @property bool isExact() { return tag == Tag.exact; }

    auto opCmp(const(MatchLevel) right) const
    {
        return this.tag - right.tag;
    }

    @property static MatchLevel noMatch() { return MatchLevel(Tag.noMatch); }
    @property private static MatchLevel pattern() { return MatchLevel(Tag.pattern); }
    @property private static MatchLevel exact()   { return MatchLevel(Tag.exact); }
}
abstract class Target
{
    //
    // Make Engine Functions
    //
    static Target create(string str)
    {
        auto varCount = count(str, '$');
        if(varCount == 0)
        {
            return new PathTarget(str);
        }
        else
        {
            return new PatternTarget(str, varCount);
        }
    }
    abstract MatchLevel matches(Item item);
}
/*
class NameTarget : Target
{
    string str;
    this(string str) { this.str = str; }
    override string toString() const { return str; }
    override MatchLevel matches(Item item)
    {
        return itemSpecifier.matchesSimple(str) ? MatchLevel.exact : MatchLevel.noMatch;
    }
}
*/
class PathTarget : Target
{
    string pathname;
    this(string pathname) { this.pathname = pathname; }
    override string toString() const { return pathname; }
    override MatchLevel matches(Item item)
    {
        return equal(path.pathSplitter(pathname), path.pathSplitter(item.getName)) ?
            MatchLevel.exact : MatchLevel.noMatch;
        //return itemSpecifier.matchesPath(pathname) ? MatchLevel.exact : MatchLevel.noMatch;
    }
}
class PatternTarget : Target
{
    string pattern;
    size_t varCount;
    this(string pattern, size_t varCount)
    {
        this.pattern = pattern;
        this.varCount = varCount;
    }
    override string toString() const { return pattern; }
    override MatchLevel matches(Item item)
    {
        return targetMatchPattern.match(pattern, item.getName) ? MatchLevel.pattern : MatchLevel.noMatch;
    }
}
/*
class GlobTarget : Target
{
    string glob;
    this(string glob) { this.glob = glob; }
    override string toString() const { return glob; }
    override MatchLevel matches(Item item)
    {
        return itemSpecifier.matchesGlob(glob) ? MatchLevel.glob : MatchLevel.noMatch;
    }
}
*/

//
// Actions
//
class Action
{
    //
    // Make Engine Functions
    //
    static Action create(T)(T action)
    {
        static if(traits.isCallable!T)
        {
            return new CallableAction!T(action);
        }
        else static assert(0, "Unable to create action from type " ~ T.stringof);
    }
    abstract void perform(Item target, Target[] ruleTargets, Item[] deps);
}
class CallableAction(T) : Action
{
    T callable;
    this(T callable) { this.callable = callable; }
    final override void perform(Item target, Target[] ruleTargets, Item[] deps)
    {
        callable(target, ruleTargets, deps);
    }
}
class CreateTargetDirectory : Action
{
    static __gshared instance = new CreateTargetDirectory();
    private this() {}
    override string toString() const { return "mkdir $TARGET"; }
    final override void perform(Item target, Target[] ruleTargets, Item[] deps)
    {
        auto dirName = target.getName;
        assert(dirName, "code bug maybe");
        io.writefln("mkdir %s", dirName);
        std.file.mkdir(dirName);
    }
}

class CreateTargetFile : Action
{
    //string name;
    string contents;
    this(/*string name, */string contents) { /*this.name = name;*/ this.contents = contents; }
    final override void perform(Item target, Target[] ruleTargets, Item[] ruleDeps)
    {
        auto fileName = target.getName;
        assert(fileName, "code bug maybe");
        io.writefln("creating %s-byte file %s", contents.length, fileName);
        auto file = io.File(fileName, "wb");
        scope(exit) file.close();
        file.write(contents);
    }
}

struct FileSystemPolicy
{
    alias Timestamp = makelib.filesystem.Timestamp;

    alias Item = makelib.filesystem.Item;
    alias ItemSpecifier = makelib.filesystem.ItemSpecifier;

    alias MatchLevel = makelib.filesystem.MatchLevel;
    alias Target = makelib.filesystem.Target;

    alias Action = makelib.filesystem.Action;
}

alias FileSystemMake = Make!FileSystemPolicy;
alias FileSystemMakeEngine = Make!FileSystemPolicy.Engine;

unittest
{
    auto engine = FileSystemMakeEngine();
    engine.verbose = true;

    enum unittest_dir = "unittest_dir";
    engine.rule()
        .target(unittest_dir)
        .action(CreateTargetDirectory.instance)
        ;

    {
        auto testfile = path.buildPath(unittest_dir, "testfile");
        engine.rule()
            .target(testfile)
            .depend(unittest_dir)
            .action(new CreateTargetFile("contents of testfile"))
            ;
    }
    {
        engine.rule()
            .target("$dir/$baseName.copy_with_pattern_rule")
            .depend("$dir/$baseName")
            .action(delegate(Item target, Target[] targets, Item[] dependencies)
            {
                auto from = dependencies[0].getName;
                auto to = target.getName;
                import std.stdio; writefln("copy '%s' to '%s'", from, to);
                std.file.copy(from, to);
            });
    }

    assert(engine.make("unittest_dir/testfile.copy_with_pattern_rule").succeeded);
}
