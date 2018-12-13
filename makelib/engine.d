module makelib.engine;

import core.stdc.stdlib : alloca;
import std.array : Appender, appender;

template from(string mod)
{
    mixin("import from = " ~ mod ~ ";");
}

struct MakeResult
{
    private enum Tag
    {
        success,
        dependencyFailed,
        noMatchingRule,
        multipleRulesWithSameMatchLevel,
    }
    private Tag tag;
    @property bool succeeded() const { return tag == Tag.success; }

    @property static MakeResult success()
        { return MakeResult(Tag.success); }
    @property static MakeResult dependencyFailed()
        { return MakeResult(Tag.dependencyFailed); }
    @property static MakeResult noMatchingRule()
        { return MakeResult(Tag.noMatchingRule); }
    @property static MakeResult multipleRulesWithSameMatchLevel()
        { return MakeResult(Tag.multipleRulesWithSameMatchLevel); }
}

enum TimestampTag
{
    notMade,
    preMadeNoTime,
    preMadeWithTime,
    newlyMade,
}

template Make(Policy)
{
    /*
    As of now, a "Target" is just a pattern that matches items.
    An Item is something to be built, meaning, it has to match a target which
       will give it's dependencies and the actions to build it.
    An ItemSpecifier is a string that represents one or more items to be built.

<target>... : <item-specifier>...
    <action>
    <action>
    ...

    */
    /*
    TODO: Add the const qualifier to these
    {
        Policy.RulePriority priority;
        if(priority.isHighest) { }
        Policy.RulePriority priority2;
        if(priority == priority2) { }
        if(priority < priority2) { }
        if(priority > priority2) { }
    }
    Policy.Target target;
    if(target.needsToBeMade()) { }
    Policy.Item item;
    Policy.RulePriority.nullValue;
    Policy.MatchLevel matchLevel = target.matches(item); // returns null or priority
    Policy.MatchLevel.noMatch;
    if(matchLevel.isMatch) { }
    if(matchLevel.isExact) { }
    if(matchLevel < Policy.MatchLevel()) { }
    if(matchLevel == Policy.MatchLevel()) { }
    if(matchLevel > Policy.MatchLevel()) { }

    if(priority.isNull) { }

    rule.build(target, matchResult);

    Policy.ItemSpecifier specifier;
    Policy.Action action;
    auto rule = Policy.Rule([target], [specifier], [action]);

    action.perform(item, rule.targets, rule.dependencies);

    Policy.ItemSpecifier specifier;
    specifier.newerThan(target);


*/
    unittest
    {
        assert(Policy.Timestamp.notMade == Policy.Timestamp.notMade);
        assert(Policy.Timestamp.notMade <  Policy.Timestamp.preMadeNoTime);
        //assert(Policy.Timestamp.notMade <  Policy.Timestamp.preMadeWithTime(SysTime.min));
        assert(Policy.Timestamp.notMade <  Policy.Timestamp.newlyMade);
    }

    struct Rule
    {
        Policy.Target[] targets;
        Policy.ItemSpecifier[] dependencies = void;
        Policy.Action[] actions = void;
        this(Policy.Target[] targets, Policy.ItemSpecifier[] dependencies, Policy.Action[] actions)
        {
            this.targets = targets;
            this.dependencies = dependencies;
            this.actions = actions;
        }
        Rule* target(Policy.Target target)
        {
            this.targets ~= target;
            return &this;
        }
        Rule* target(T...)(T args)
        {
            this.targets ~= Policy.Target.create(args);
            return &this;
        }

        Rule* depend(Policy.ItemSpecifier specifier)
        {
            this.dependencies ~= specifier;
            return &this;
        }
        Rule* depend(T...)(T args)
        {
            this.dependencies ~= Policy.ItemSpecifier.create(args);
            return &this;
        }

        Rule* action(Policy.Action newAction)
        {
            this.actions ~= newAction;
            return &this;
        }
        Rule* action(T...)(T args)
        {
            this.actions ~= Policy.Action.create(args);
            return &this;
        }
    }
    struct RuleAndPriority
    {
        Rule rule;
        Policy.MatchLevel matchResult;
    }

    struct Engine
    {
        bool verbose;
        Appender!(Rule[]) rules;

        Rule* rule()
        {
            rules.put(Rule());
            return &rules.data[$-1];
        }

        void dumpRules()
        {
            foreach(ref rule; rules.data)
            {
                import std.stdio; writefln("%s", rule);
            }
        }
        void dumpTargets()
        {
            foreach(ref rule; rules.data)
            {
                foreach(target; rule.targets)
                {
                    import std.stdio; writefln("%s", target);
                }
            }
        }

        void addRule(
            Policy.Target[] targets,
            Policy.ItemSpecifier[] dependencies,
            Policy.Action[] actions)
        {
            rules.put(Rule(targets, dependencies, actions));
        }

        struct FindRuleResult
        {
            Rule* rule;
            Policy.Target target;
            enum Tag
            {
                none, found, multipleFoundWithSameMatchLevel,
            }
            Tag tag;
        }
        private void findRule(FindRuleResult* result, Policy.Item item)
        {
            Rule* currentMatchRule = null;
            Policy.Target currentMatchTarget = void;
            Policy.MatchLevel currentMatchLevel = void;
            auto sameLevelMatches = appender!(Rule*[])();
            foreach(ref rule; rules.data)
            {
                //from!"std.stdio".writefln("[DEBUG] checking rule %s", rule);
                foreach(target; rule.targets)
                {
                    auto matchLevel = target.matches(item);
                    if(matchLevel.isMatch)
                    {
                        if(matchLevel.isExact)
                        {
                            *result = FindRuleResult(&rule, target, FindRuleResult.Tag.found);
                            return;
                        }

                        if(currentMatchRule is null)
                        {
                            currentMatchRule = &rule;
                            currentMatchTarget = target;
                        }
                        else if(matchLevel > currentMatchLevel)
                        {
                            currentMatchRule = &rule;
                            currentMatchTarget = target;
                            currentMatchLevel = matchLevel;
                            sameLevelMatches.clear();
                        }
                        else if(matchLevel == currentMatchLevel)
                        {
                            sameLevelMatches.put(&rule);
                        }
                    }
                }
            }

            if(currentMatchRule is null)
            {
                result.tag = FindRuleResult.Tag.none;
                return;
            }
            if(sameLevelMatches.data.length > 0)
            {
                import std.stdio; writefln("Error: '%s' matches multiple rules", item);
                // TODO: print out all the matching rules
                result.tag = FindRuleResult.Tag.multipleFoundWithSameMatchLevel;
                return;
            }
            *result = FindRuleResult(currentMatchRule, currentMatchTarget, FindRuleResult.Tag.found);
            return;
        }

        final MakeResult make(T...)(T args)
        {
            auto itemSpecifier = Policy.ItemSpecifier.create(args);
            Policy.Timestamp latest = Policy.Timestamp.notMade;
            return make(itemSpecifier, null, null, null, &latest);
        }

        private static ushort staticDepth = 0;
        @property private static auto formatDepth(ushort depth)
        {
            static struct Formatter
            {
                size_t depth;
                void toString(scope void delegate(const(char)[]) sink)
                {
                    foreach(i; 0..depth) sink("   ");
                }
            }
            return Formatter(depth);
        }

        /**
        $(D latest) is both an input/output parameter.  the item's current timestamp will be
        assigned to it only if it's current timestamp is newer than the current $(D latest).
        Note that this means if $(D latest) is already the max value, then there's no need
        to get the current timestamp of $(D item).
        */
        final MakeResult make(Policy.ItemSpecifier itemSpecifier, Policy.Target targetCause,
            Policy.Item itemCause, Appender!(Policy.Item[])* itemsMade, Policy.Timestamp* latest)
        {
            auto currentDepth = staticDepth++;
            scope(exit) staticDepth--;

            pragma(inline) @property auto formatCurrentDepth() { return formatDepth(currentDepth); }
            //from!"std.stdio".writefln("[DEBUG] %smake %s", formatCurrentDepth, itemSpecifier);

            //from!"std.stdio".writefln("[DEBUG] %sgetting items from '%s'", formatCurrentDepth, itemSpecifier);
            void* rangeData = null;
            auto rangeDataSize = itemSpecifier.getRangeDataSize();
            if(rangeDataSize > 0)
            {
                //from!"std.stdio".writefln("rangeDataSize = %s", rangeDataSize);
                rangeData = alloca(rangeDataSize);
                //from!"std.stdio".writefln("rangeData = %s", rangeData);
                assert(rangeData, "alloca failed");
            }
            itemSpecifier.initItemRange(rangeData, targetCause, itemCause);
            for(; !itemSpecifier.empty(rangeData); itemSpecifier.popFront(rangeData))
            {
                auto item = itemSpecifier.front(rangeData);
                auto result = makeItem(item, latest, currentDepth);
                if(!result.succeeded)
                {
                    return result;
                }
                if(itemsMade)
                {
                    itemsMade.put(item);
                }
            }

            return MakeResult.success;
        }
        private final MakeResult makeItem(Policy.Item item, Policy.Timestamp* outLatest, ushort currentDepth)
        {
            pragma(inline) @property auto formatCurrentDepth() { return formatDepth(currentDepth); }

            // import std.stdio; writefln("[DEBUG] %smakeItem '%s'", formatCurrentDepth, item);

            // Optimization
            {
                auto timestamp = item.getTimestampIfAlreadyBuilt();
                if(timestamp.tag != TimestampTag.notMade)
                {
                    if(timestamp > *outLatest)
                    {
                        *outLatest = timestamp;
                        //from!"std.stdio".writefln("[DEBUG] latest = %s makeItem(%s) [1]", *latest, item);
                    }
                    return MakeResult.success;
                }
            }

            FindRuleResult findRuleResult = void;
            findRule(&findRuleResult, item);

            final switch(findRuleResult.tag) with (FindRuleResult.Tag)
            {
            case none:
            {
                //from!"std.stdio".writefln("[DEBUG] %s matched NO RULE", item);
                auto timestamp = item.getTimestampNoRule();
                if(timestamp.tag == TimestampTag.notMade)
                {
                    from!"std.stdio".writefln("Error: no rule to make '%s'", item);
                    return MakeResult.noMatchingRule;
                }
                if(verbose)
                {
                    from!"std.stdio".writefln("item '%s' has no rule and is already made", item);
                }
                if(timestamp > *outLatest)
                {
                    *outLatest = timestamp;
                    //from!"std.stdio".writefln("[DEBUG] latest = %s makeItem(%s) [2]", *latest, item);
                }
                return MakeResult.success;
            }
            case found:
                //from!"std.stdio".writefln("[DEBUG] %s matched rule %s", item, *findRuleResult.rule);
                break;
            case multipleFoundWithSameMatchLevel:
                // error already printed
                return MakeResult.multipleRulesWithSameMatchLevel;
            }

            //auto resolvedDependencies = resolveDependencies(findRuleResult.rule.dependencies);

            // go through all the dependency item specifiers
            //from!"std.stdio".writefln("[DEBUG] %sbuilding dependencies for '%s'", formatCurrentDepth, item);
            // TODO: don't need to keep track of dependency items if
            //       1) there are NO actions to perform
            //       2) could query the actions if they need dependency items
            auto dependencyItems = appender!(Policy.Item[])();
            dependencyItems.reserve(findRuleResult.rule.dependencies.length);
            auto latestDependency = Policy.Timestamp.notMade;

            foreach(dependency; findRuleResult.rule.dependencies)
            {
                //from!"std.stdio".writefln("[DEBUG] building dependency '%s'", dependency);
                auto result = make(dependency, findRuleResult.target, item, &dependencyItems, &latestDependency);
                if(!result.succeeded)
                {
                    return MakeResult.dependencyFailed;
                }
            }

            //from!"std.stdio".writefln("[DEBUG] makeItem %s", item);
            //if(*latest != Policy.Timestamp.max)
            //{
                //from!"std.stdio".writefln("[DEBUG] getTimestamp(%s)", item);
                auto itemTimestamp = item.getTimestamp();
                if(itemTimestamp.tag == TimestampTag.notMade)
                {
                    if(verbose)
                    {
                        from!"std.stdio".writefln("%s is not made", item);
                    }
                }
                else if(itemTimestamp.tag != TimestampTag.preMadeNoTime && itemTimestamp < latestDependency)
                {
                    if(verbose)
                    {
                        from!"std.stdio".writefln("%s is not up-to-date (itemTimestamp %s < latestDependency %s)",
                            item, itemTimestamp, latestDependency);
                    }
                }
                else
                {
                    if(itemTimestamp > *outLatest)
                    {
                        *outLatest = itemTimestamp;
                        //from!"std.stdio".writefln("[DEBUG] latest = %s makeItem(%s) [3]", *latest, item);
                    }
                    if(verbose)
                    {
                        import std.stdio; writefln("%s is already made and up-to-date", item);
                    }
                    return MakeResult.success;
                }
            //}

            if(verbose)
            {
                import std.stdio; writefln("making %s", item);
            }
            foreach(action; findRuleResult.rule.actions)
            {
                action.perform(item, findRuleResult.rule.targets, dependencyItems.data);
            }
            item.notifyBuilt();
            // TODO: only check this if the item "CAN" be made
            //if(item.needsToBeMade())
            //{
            //}
            *outLatest = Policy.Timestamp.newlyMade();
            //from!"std.stdio".writefln("[DEBUG] latest = %s makeItem(%s) [4]", *latest, item);
            return MakeResult.success;
        }
    }
}

unittest
{
    static struct TestTimestamp
    {
        TimestampTag tag;
        @property static auto notMade()         { return TestTimestamp(TimestampTag.notMade); }
        @property static auto preMadeNoTime()   { return TestTimestamp(TimestampTag.preMadeNoTime); }
        @property static auto newlyMade()       { return TestTimestamp(TimestampTag.newlyMade); }
        auto opCmp(const(TestTimestamp) right) const
        {
            return this.tag - right.tag;
        }
    }

    //
    // Objects
    //
    static class TestItem
    {
        private string name;
        TestTimestamp timestamp;
        private bool built;
        this(string name, TestTimestamp timestamp)
        {
            this.name = name;
            this.timestamp = timestamp;
        }
        void notifyBuilt() { this.built = true; }
        auto getTimestamp() const
        {
            return timestamp;
        }
        auto getTimestampNoRule() const
        {
            return timestamp;
        }
        auto getTimestampIfAlreadyBuilt() const
        {
            return built ? timestamp : TestTimestamp.notMade;
        }
        override string toString() const
        {
            return name;
        }
    }

    static struct Kitchen
    {
        private static TestItem[string] table;
        static void reset()
        {
            table = null;
        }
        static TestItem getOrCreate(string name)
        {
            auto entry = table.get(name, null);
            if(entry is null)
            {
                entry = new TestItem(name, TestTimestamp.notMade);
                table[name] = entry;
            }
            return entry;
        }
        static void add(string name, TestTimestamp timestamp)
            in { assert(timestamp != TestTimestamp.notMade); } do
        {
            assert(table.get(name, null) is null);
            table[name] = new TestItem(name, timestamp);
        }
    }

    static struct TestMatchLevel
    {
        @property static auto noMatch() { return TestMatchLevel(false); }

        bool _matches;
        @property bool isMatch() const { return _matches; }
        @property bool isExact() const { return _matches; }
        alias _matches this;
    }
    static class TestTarget
    {
        string name;
        this(string name) { this.name = name; }
        auto matches(TestItem item)
        {
            auto result = (this.name == item.name);
            //import std.stdio;
            //writefln(" globMatch(\"%s\", \"%s\") > %s", this.glob, item.glob, result);
            return TestMatchLevel(result);
        }
        override string toString() { return name; }
    }

    static class TestItemSpecifier
    {
        static auto create(string str) { return new TestItemSpecifier(str); }
        TestItem item;
        this(string str)
        {
            this.item = Kitchen.getOrCreate(str);
        }
        override string toString() { return item.name; }

        size_t getRangeDataSize() { return 1; }
        void initItemRange(void* buffer, TestTarget target, TestItem item) { (cast(ubyte*)buffer)[0] = 0; }
        bool empty(void* buffer) const { return (cast(ubyte*)buffer)[0] != 0; }
        auto front(void* buffer) inout { return item; }
        void popFront(void* buffer)
        {
            (cast(ubyte*)buffer)[0] = 1;
        }
    }


    //
    // Actions
    //
    static struct TestAction
    {
        private string actionString;
        void perform(TestItem item, TestTarget[] targets, TestItem[] dependencies)
        {
            import std.stdio;
            writefln("Action: %s (target=%s)", actionString, item);
        }
    }

    static struct TestPolicy
    {
        alias Timestamp = TestTimestamp;

        alias Item = TestItem;
        alias ItemSpecifier = TestItemSpecifier;

        alias MatchLevel = TestMatchLevel;
        alias Target = TestTarget;

        alias Action = TestAction;
    }
    {
        auto engine = Make!TestPolicy.Engine();
        //engine.verbose = true;
        Kitchen.reset();
        Kitchen.add("sugar", TestTimestamp.preMadeNoTime);
        Kitchen.add("flour", TestTimestamp.preMadeNoTime);
        engine.addRule(
            [new TestTarget("cake")],
            [new TestItemSpecifier("sugar"), new TestItemSpecifier("flour")],
            [TestAction("mix"), TestAction("bake")]);
        assert(engine.make("cake").succeeded);
    }
}
