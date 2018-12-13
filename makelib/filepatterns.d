module makelib.filepatterns;

import std.algorithm : canFind;
import std.string : endsWith;
import std.path : isDirSeparator;
import path = std.path;

bool validPatternNameChar(char c)
{
    if(c >= 'a') return c <= 'z';
    if(c >= 'A') return c <= 'Z';
    if(c >= '0') return c <= '9';
    return c == '_';
}

//
// NOTE:
// for now I'm implementing a simple version of the pattern matching
//
template namedPattern(Policy)
{
    bool match(const(char)[] pattern, const(char)[] str, Policy.OnMatchArgs onMatchArgs)
    {
        auto patternIterator = path.pathSplitter(pattern);
        auto strIterator     = path.pathSplitter(str);
        for(;;)
        {
            if(patternIterator.empty())
            {
                return strIterator.empty();
            }
            if(strIterator.empty())
            {
                return false;
            }

            auto nextPattern = patternIterator.front;
            auto nextStr = strIterator.front;
            if(nextPattern.length > 0 && nextPattern[0] == '$')
            {
                if(nextPattern.length == 1)
                {
                    Policy.onMatchedName(null, nextStr, onMatchArgs);
                }
                else
                {
                    size_t next = 1;
                    if(nextPattern[next] == '*')
                    {
                        next++;
                        assert(0, "multi-path not implemented");
                    }
                    auto nameStart = next;
                    typeof(next) nameEnd;
                    for(;; next++)
                    {
                        if(next >= nextPattern.length)
                        {
                            nameEnd = next;
                            break;
                        }
                        auto nextChar = nextPattern[next];
                        if(!validPatternNameChar(nextChar))
                        {
                            nameEnd = next;
                            if(nextChar == ';')
                            {
                                next++;
                            }
                            break;
                        }
                    }

                    auto patternRest = nextPattern[next .. $];
                    assert(!canFind(patternRest, '$'), "not implemented");
                    //import std.stdio; writefln("patternRest = '%s'", patternRest);
                    if(!nextStr.endsWith(patternRest))
                    {
                        return false;
                    }
                    auto nameLength = nameEnd - nameStart;
                    Policy.onMatchedName(nextPattern[nameStart .. nameEnd],
                        nextStr[0 .. $ - patternRest.length], onMatchArgs);
                }
            }
            else
            {
                assert(!canFind(nextPattern, '$'), "not implemented");
                if(nextPattern != nextStr)
                {
                    return false;
                }
            }

            patternIterator.popFront();
            strIterator.popFront();
        }

    }
}



/+
/++
Matching:

/foo/$dirname/bar
    MATCHES /foo/a/bar   $dirname == "a"
    NOMATCH /foo/a/b/bar

$name
    MATCHES a      $name = "a"
    NOMATCH a/b

$name;a
    MATCHES a      $name = ""
    MATCHES ba     $name = "b"
    NOMATCH ab

$0;a
    MATCHES a      $0 = ""
    MATCHES ba     $0 = "b"
    NOMATCH ab

$*path/file
    MATCHES /file     $path = ""
    MATCHES a/file    $path = "a"
    MATCHES a/b/file  $path = "a/b"
+/
template namedPattern(Policy)
{
    bool match(const(char)[] pattern, const(char)[] str, Policy.MatchNameType matchType)
    {
        size_t patternNext = 0;
        size_t strNext;
        for(; patternNext < pattern.length;)
        {
            if(strNext >= str.length)
            {
                return canMatchEmpty(pattern[patternNext..$], matchType);
            }

            auto c = pattern[patternNext];
            if(path.isDirSeparator(c))
            {
                assert(0, "not implemented");
            }
            else if(c == Policy.escapeChar)
            {
                patternNext++;
                if(patternNext >= pattern.length)
                {
                    return !canFind!isDirSeparator(str[strNext..$]);
                }
                bool multipath = false;
                if(pattern[patternNext] == '*')
                {
                    multipath = true;
                    patternNext++;
                    if(patternNext >= pattern.length)
                    {
                        return true;
                    }
                    assert(0, "multi-path match not implemented");
                }
                {
                    auto nameStart = next;
                    char c = pattern[next];
                    for(;;)
                    {
                        c = pattern[next];
                        if(!validPatternNameChar(c))
                        {
                            break;
                        }
                        next++;
                        if(next >= pattern.length)
                        {
                            Policy.onMatchedName(matchType, pattern[nameStart .. $], null);
                            return true;
                        }
                    }
                    Policy.onMatchedName(matchType, pattern[nameStart .. next], null);
                    if(c == ';')
                    {
                        next++;
                        if(next >= pattern.length)
                            return true;
                    }
                }
            }
            else
            {
                if(c != str[strNext])
                {
                    return false;
                }
                patternNext++;
                strNext++;
            }

        }
        return strNext == str.length;
    }
    private bool canMatchEmpty(char escapeChar = '$')(const(char)[] pattern, Policy.MatchNameType matchType)
    {
        import std.stdio; writefln("canMatchEmpty('%s')", pattern);
        if(pattern.length == 0)
        {
            return true;
        }
        auto next = 0;
        for(;;)
        {
            if(pattern[next] != Policy.escapeChar)
            {
                return false;
            }
            next++;
            if(next >= pattern.length)
                return true;

            if(pattern[next] == '*')
            {
                next++;
                if(next >= pattern.length)
                    return true;
            }
            {
                auto nameStart = next;
                char c = pattern[next];
                for(;;)
                {
                    c = pattern[next];
                    if(!validPatternNameChar(c))
                    {
                        break;
                    }
                    next++;
                    if(next >= pattern.length)
                    {
                        Policy.onMatchedName(matchType, pattern[nameStart .. $], null);
                        return true;
                    }
                }
                Policy.onMatchedName(matchType, pattern[nameStart .. next], null);
                if(c == ';')
                {
                    next++;
                    if(next >= pattern.length)
                        return true;
                }
            }
        }
    }
}
+/

private template tuple(T...) { alias tuple = T; }
struct TargetMatchPatternPolicy
{
    enum escapeChar = '$';
    alias OnMatchArgs = tuple!();
    pragma(inline) static void onMatchedName(const(char)[] name, const(char)[] value) { }
}
alias targetMatchPattern = namedPattern!TargetMatchPatternPolicy;

version(unittest)
{
    struct Pair
    {
        string name;
        string value;
    }
    static void testFail(string pattern, string str)
    {
        //import std.stdio; writefln("testing mismatch '%s' with '%s'", pattern, str);
        assert(!targetMatchPattern.match(pattern, str));
    }
    static void testMatch(string pattern, string str, Pair[] namedPairs...)
    {
        static struct NamedPairVerifier
        {
            Pair[] namedPairs;
            size_t next;
        }
        static struct Policy
        {
            enum escapeChar = '$';
            alias OnMatchArgs = NamedPairVerifier*;
            static void onMatchedName(const(char)[] name, const(char)[] value, NamedPairVerifier* verifier)
            {
                //import std.stdio; writefln("name = '%s', value = '%s', next = %s", name, value, verifier.next);
                assert(verifier.next < verifier.namedPairs.length);
                assert(verifier.namedPairs[verifier.next].name == name);
                assert(verifier.namedPairs[verifier.next].value == value);
                verifier.next++;
            }
        }
        //import std.stdio; writefln("testing pattern '%s' with '%s'", pattern, str);
        auto verifier = NamedPairVerifier(namedPairs, 0);
        assert(namedPattern!Policy.match(pattern, str, &verifier));
        assert(verifier.next == namedPairs.length);
    }
}

unittest
{
    //test(true , "$0", "a");
    //test(false, "$0", "a/b");
}

unittest
{
    testMatch(null, null);
    testMatch(  "", null);
    testMatch(null,   "");
    testFail ( "a", null);
    testFail ( "a",   "");
    testFail (null,   "a");
    testFail (  "",   "a");

    testFail ("$", null);
    testFail ("$",   "");
    testMatch("$",  "a", Pair(null, "a"));

    testFail ("$0", null);
    testFail ("$0",   "");
    testMatch("$0",  "a", Pair("0", "a"));

    testFail ("$0/b", null);
    testFail ("$0/b",   "");
    testFail ("$0/b",  "a");
    testMatch("$0/b", "a/b", Pair("0", "a"));
    testFail ("$0/b", "a/c");
    testFail ("$0/b", "a/b/c");

    testFail ("a/$0", null);
    testFail ("a/$0", "");
    testFail ("a/$0", "a");
    testMatch("a/$0", "a/b", Pair("0", "b"));
    testFail ("a/$0", "b/b");

    testFail ("$0;", null);
    testFail ("$0;",   "");
    testMatch("$0;",  "a", Pair("0", "a"));

    testFail ("$;", null);
    testFail ("$;",   "");
    testMatch("$;",  "a", Pair("",  "a"));

    testMatch("$first",  "a", Pair("first",  "a"));
    testMatch("$first;",  "a", Pair("first",  "a"));
    testMatch("$first;b",  "ab", Pair("first",  "a"));
    testMatch("$first.exe",  "a.exe", Pair("first",  "a"));
    /*

    testMatch("$*", null, Pair("", null));
    testMatch("$*",   "", Pair("",   ""));
    testMatch("$*",  "a", Pair("",  "a"));

    */
}
