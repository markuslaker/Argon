#!/usr/bin/rdmd --shebang -unittest -g -debug

module argon;

/+
Copyright (c) 2016, Mark Stephen Laker

Permission to use, copy, modify, and/or distribute this software for any
purpose with or without fee is hereby granted, provided that the above
copyright notice and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
+/

import core.exception;
import std.algorithm.iteration;
import std.algorithm.searching;
import std.algorithm.sorting;
import std.array;
import std.conv;
import std.exception;
import std.regex;
import std.stdio;
import std.traits;
import std.uni;

@safe {

// These filenames are used for unittest blocks.  Feel free to increase test
// coverage by adding stanzas for other operating systems.

version(linux) {
    immutable existent_file    = "/dev/zero";
    immutable nonexistent_file = "/dev/onshire-ice-cream";
}
else {
    immutable existent_file    = "";
    immutable nonexistent_file = "";
}

/++
 + If the user specifies invalid input at the command line, Argon will throw
 + a ParseException.  This class is a subclass of Exception, and so you can
 + extract the text of the exception by calling `.msg()` on it.
 +/

class ParseException: Exception {
    this(A...) (A a) {
        super(text(a));
    }
}

/++
 + You can optionally use an indicator to tell whether an argument was supplied
 + at the command line.
 +/

enum Indicator {
    NotSeen,            /// The user didn't specify the argument
    UsedEolDefault,     /// The user specified the named option at the end of the line and relied on the end-of-line default
    UsedEqualsDefault,  /// The user specified the named option but didn't follow it with `=' and a value
    Seen                /// The user specified the argument
}

// FArg -- formal argument (supplied in code); AArg -- actual argument (supplied
// by the user at runtime).

// This is the base class for all FArg classes:

class FArgBase {
private:
    string[] names;                 // All long names, without dashes
    string description;             // The meaning of an argument: used when we auto-generate an element of a syntax summary from a named option
    dchar shortname;                // A single-char shortcut
    bool needs_aarg;                // Always true except for bool fargs
    Indicator *p_indicator;         // Pointer to the caller's indicator, or null
    bool seen;                      // Have we matched an AArg with this FArg?
    bool positional;                // Is this positional -- identified by its position on the command line, matchable without an option name?
    bool mandatory;                 // If true, some AArg must match this FArg or parsing will fail
    bool documented = true;         // True if this FArg should appear in syntax summaries
    bool has_eol_default;           // Has an end-of-line default value
    bool has_equals_default;        // Any actual arg must be attached with `=', and --switch without `=' is a shorthand for equals_default
    bool is_incremental;            // Is an incremental argument, which increments its receiver each time it's seen

    auto SetSeen(in Indicator s) {
        seen = s != Indicator.NotSeen;
        if (p_indicator)
            *p_indicator = s;
    }

protected:
    this(in string nms, in bool na, Indicator *pi) {
        names       = nms.splitter('|').filter!(name => !name.empty).array;
        needs_aarg  = na;
        p_indicator = pi;

        if (pi)
            *pi = Indicator.NotSeen;
    }

    auto MarkSeen()                     { SetSeen(Indicator.Seen); }
    auto MarkSeenWithEolDefault()       { SetSeen(Indicator.UsedEolDefault); }
    auto MarkSeenWithEqualsDefault()    { SetSeen(Indicator.UsedEqualsDefault); }
    auto MarkUnseen()                   { SetSeen(Indicator.NotSeen); }
    auto SetShortName(in dchar snm)     { shortname       = snm; }
    auto SetDescription(in string desc) { description     = desc; }
    auto MarkUndocumented()             { documented      = false; }
    auto MarkIncremental()              { is_incremental  = true; }

    auto MarkEolDefault() {
        assert(!HasEqualsDefault, "A single argument can't have both an end-of-line default and an equals default"); 
        has_eol_default = true;
    }

    auto MarkEqualsDefault()            { 
        assert(!HasEolDefault, "A single argument can't have both an end-of-line default and an equals default"); 
        has_equals_default = true;
    }

public:
    auto GetFirstName() const           { return names[0]; }
    auto GetNames() const               { return names; }
    auto HasShortName() const           { return shortname != shortname.init; }
    auto GetShortName() const           { return shortname; }
    auto GetDescription() const         { return description; }
    auto NeedsAArg() const              { return needs_aarg; }
    auto IsPositional() const           { return positional; }
    auto IsNamed() const                { return !positional; }
    auto IsMandatory() const            { return mandatory; }
    auto HasBeenSeen() const            { return seen; }
    auto IsDocumented() const           { return documented; }
    auto HasEolDefault() const          { return has_eol_default; }
    auto IsIncremental() const          { return is_incremental; }
    auto HasEqualsDefault() const       { return has_equals_default; }

    /++
     + Adds a single-letter short name (not necessarily Ascii) to avoid the need
     + for users to type out the long name.
     +
     + Only a named option can have a short name.  A positional argument
     + doesn't need one, because its name is never typed in by users.
     +/

    auto Short(this T) (in dchar snm) {
        assert(!positional,           "A positional argument can't have a short name");
        assert(!std.uni.isWhite(snm), "An option's short name can't be a whitespace character");
        assert(snm != '-',            "An option's short name can't be a dash, because '--' would be interpreted as the end-of-options token");
        assert(snm != '=',            "An option's short name can't be an equals sign, because '=' is used to conjoin values with short option names and would be confusing with bundling enabled");
        SetShortName(snm);
        return cast(T) this;
    }

    /// Sugar for adding a single-character short name:
    auto opCall(this T) (in dchar snm) {
        return cast(T) Short(snm);
    }

    /++
     + Adds a description, which is used in error messages.  It's also used when
     + syntax summaries are auto-generated, so that we can generate something
     + maximally descriptive like `--windows <number of windows>`.  Without
     + this, we'd either generate the somewhat opaque `--windows <windows>`
     + or have to impose extra typing on the user by renaming the option as
     + `--number-of-windows`.
     +
     + The description needn't be Ascii.
     +
     + Only a named option can have a description.  For a positional
     + argument, the name is never typed by the user and it does double duty
     + as a description.
     +/

    auto Description(this T) (in string desc) {
        assert(!positional, "A positional argument doesn't need a description: use the ordinary name field for that");
        FArgBase.SetDescription(desc);
        return cast(T) this;
    }

    /// Sugar for adding a description:
    auto opCall(this T) (in string desc) {
        return cast(T) Description(desc);
    }

    /// Excludes an argument from auto-generated syntax summaries:
    auto Undocumented(this T) () {
        MarkUndocumented();
        return cast(T) this;
    }

    // Indicate that this can be a positional argument:
    auto MarkPositional()               { positional = true; }

    // Indicate that this argument is mandatory:
    auto MarkMandatory()                { mandatory = true; }

    // The framework tells us to set default values before we start:
    abstract void SetFArgToDefault();

    // We've been passed an actual argument:
    enum InvokedBy {LongName, ShortName, Position};

    abstract void See(in string aarg, in InvokedBy);
    abstract void SeeEolDefault();
    abstract void SeeEqualsDefault();

    // Overridden by BoolFArg and IncrementalFArg only:
    void See() {
        assert(false);
    }

    // Produce a string such as "the --alpha option (also known as --able and
    // --alfie and --alfred)".

    auto DisplayAllNames() const {
        string result = "the --" ~ names[0] ~ " option";
        if (names.length > 1) {
            auto prefix = " (also known as --";
            foreach (name; names[1..$]) {
                result ~= prefix;
                result ~= name;
                prefix  = " and --";
            }
            result ~= ')';
        }

        return result;
    }

    // Not capitalised; don't use the description at the start of a sentence:
    auto DescribeArgumentForError(in InvokedBy invocation) const {
        final switch (invocation) {
        case InvokedBy.LongName:
            assert(!positional);
            return !description.empty? description: DisplayAllNames;
        case InvokedBy.ShortName:
            assert(!positional);
            assert(HasShortName);
            return !description.empty? description: text("the -", shortname, " option");
        case InvokedBy.Position:
            assert(positional);
            return text("the ", names[0]);
        }
    }

    auto DescribeArgumentOptimallyForError() const {
        immutable invocation = IsPositional? InvokedBy.Position: InvokedBy.LongName;
        return DescribeArgumentForError(invocation);
    }

    static FirstNonEmpty(string a, string b) {
        return !a.empty? a: b;
    }

    auto BuildBareSyntaxElement() const {
        if (IsPositional)
            return text('<', GetFirstName, '>');

        immutable stump = text("--", GetFirstName);
        if (!NeedsAArg)
            return stump;

        return text(stump, " <", FirstNonEmpty(GetDescription, GetFirstName), '>');
    }

    auto BuildSyntaxElement() const {
        return IsMandatory?     BuildBareSyntaxElement:
               IsIncremental?   BuildBareSyntaxElement ~ '*':
                                text('[', BuildBareSyntaxElement, ']');
    }

    // After all aargs have been seen, every farg gets the chance to postprocess
    // any aarg or default it's been given.
    void Transform() { }
}

// Holding the receiver pointer in a templated base class separate from the
// rest of the inherited functionality makes it easier for the compiler to
// avoid bloat by reducing the amount of templated code.

class HasReceiver(FArg): FArgBase {
protected:
    FArg *p_receiver;
    FArg dfault;
    FArg special_default;   // Either an EOL default or an equals default -- no argument can have both

    this(in string name, in bool needs_aarg, Indicator *p_indicator, FArg *pr, FArg df) {
        super(name, needs_aarg, p_indicator);
        p_receiver = pr;
        dfault     = df;
    }

    // Returns a non-empty error message on failure or null on success:
    string ViolatesConstraints(in FArg, in InvokedBy) {
        return null;
    }

    abstract FArg Parse(in char[] aarg, in InvokedBy invocation);

    override void SeeEolDefault() {
        *p_receiver = special_default;
        MarkSeenWithEolDefault;
    }

    override void SeeEqualsDefault() {
        *p_receiver = special_default;
        MarkSeenWithEqualsDefault;
    }

    void SetEolDefault(FArg def) {
        assert(IsNamed, "Only a named option can have an end-of-line default; for a positional argument, use an ordinary default");
        special_default = def;
        MarkEolDefault;
    }

    void SetEqualsDefault(FArg def) {
        assert(IsNamed, "Only a named option can have an equals default; for a positional argument, use an ordinary default");
        special_default = def;
        MarkEqualsDefault;
    }

public:
    final override void SetFArgToDefault() {
        *p_receiver = dfault;  
        MarkUnseen;
    }

    override void See(in string aarg, in InvokedBy invocation) {
        *p_receiver = Parse(aarg, invocation);
        if (const msg = ViolatesConstraints(*p_receiver, invocation))
            throw new ParseException(msg);

        MarkSeen;
    }
}

/++
 + Adds the ability to set an end-of-line and equals defaults and return this.
 + The only FArg classes that don't get this are Booleans (for which the idea of
 + an EOL default makes no sense) and File (whose FArg makes its own provision).
 +/

mixin template CanSetSpecialDefaults() {
    /++
     + Provides an end-of-line default for a named option.  This default is
     + used only if the user specifies the option name as the last token on
     + the command line and doesn't follow it with a value.  For example:
     + ----
     + class MyHandler: argon.Handler {
     +     uint width;
     +
     +     this() {
     +         Named("wrap", width, 0).SetEolDefault(80);
     +     }
     +
     +     // ...
     + }
     + ----
     + Suppose your command is called `list-it`.  If the user runs `list-it`
     + with no command line arguments, `width` will be zero.  If the user runs
     + `list-it --wrap` then `width` will equal 80.  If the user runs
     + `list-it --wrap 132` then `width` will equal 132.
     +
     + An end-of-line default provides the only way for a user to type the name
     + of a non-Boolean option without providing a value.
     +/

    auto EolDefault(T) (T def) {
        SetEolDefault(def);
        return this;
    }

    /++
     + Provides an equals default for a named option, which works like
     + grep's --colour option:
     +
     + * Omitting --colour is equivalent to --colour=none
     +
     + * Supplying --colour on its own is equivalent to --colour=auto
     +
     + * Any other value must be attached to the --colour switch by one equals
     +   sign and no space, as in --colour=always
     +/

    auto EqualsDefault(T) (T def) {
        SetEqualsDefault(def);
        return this;
    }    
}

// Holds a FArg for a Boolean AArg.

class BoolFArg: HasReceiver!bool {
    this(in string name, bool *p_receiver, bool dfault) {
        super(name, false, null, p_receiver, dfault);
    }

    alias See = HasReceiver!bool.See;

    override void See() {
        *p_receiver = !dfault;
        MarkSeen;
    }

protected:
    override bool Parse(in char[] aarg, in InvokedBy invocation) {
        if (!aarg.empty) {
            if ("no" .startsWith(aarg) || "false".startsWith(aarg) || aarg == "0")
                return false;
            if ("yes".startsWith(aarg) || "true" .startsWith(aarg) || aarg == "1")
                return true;
        }

        throw new ParseException("Invalid argument for ", DescribeArgumentForError(invocation));
    }
}

@system unittest {
    // unittest blocks such as this one have to be @system because they take
    // the address of a local var, such as `target'.
    alias InvokedBy = FArgBase.InvokedBy;

    bool target;

    auto ba0 = new BoolFArg("big red switch setting", &target, false);
    assert(ba0.GetFirstName == "big red switch setting");
    assert(!ba0.HasShortName);
    assert(!ba0.IsPositional);
    assert(!ba0.IsMandatory);
    assert(!ba0.HasBeenSeen);

    ba0.MarkMandatory;
    assert(ba0.IsMandatory);

    ba0.MarkPositional;
    assert(ba0.IsPositional);

    assert(!target);
    ba0.See;
    assert(target);
    ba0.See("n", InvokedBy.Position);
    assert(!target);
    ba0.See("y", InvokedBy.Position);
    assert(target);
    ba0.See("no", InvokedBy.Position);
    assert(!target);
    ba0.See("yes", InvokedBy.Position);
    assert(target);

    ba0.See("f", InvokedBy.Position);
    assert(!target);
    ba0.See("t", InvokedBy.Position);
    assert(target);
    ba0.See("fa", InvokedBy.Position);
    assert(!target);
    ba0.See("tr", InvokedBy.Position);
    assert(target);
    ba0.See("fal", InvokedBy.Position);
    assert(!target);
    ba0.See("tru", InvokedBy.Position);
    assert(target);
    ba0.See("false", InvokedBy.Position);
    assert(!target);
    ba0.See("true", InvokedBy.Position);
    assert(target);

    ba0.See("0", InvokedBy.Position);
    assert(!target);
    ba0.See("1", InvokedBy.Position);
    assert(target);

    try {
        ba0.See("no!", InvokedBy.Position);
        assert(false, "BoolFArg should have thrown a ParseException as a result of an invalid actual argument");
    }
    catch (ParseException x)
        assert(x.msg == "Invalid argument for the big red switch setting", "Message was: " ~ x.msg);

    auto ba1 = new BoolFArg("big blue switch setting", &target, false);
    ba1('j');
    assert(ba1.HasShortName);
    assert(ba1.GetShortName == 'j');
}

// Common functionality for all numeric FArgs, whether integral or floating:

class NumericFArgBase(Num, Num RangeInterval): HasReceiver!Num {
private:
    // Implements AddRange(), which permits callers to specify one or more
    // ranges of acceptable AArgs:
    static struct ValRange(Num) {
        alias Self = ValRange!Num;
        Num minval, maxval;

        auto MergeWith(in ref Self other) {
            if (other.minval >= this.maxval && other.minval - this.maxval <= RangeInterval) {
                this.maxval = other.maxval;
                return true;
            }

            return false;
        }

        auto opCmp(in ref Self other) const {
            return this.minval < other.minval?  -1:
                   this.minval > other.minval?  +1:
                                                0;
        }

        auto toString() const {
            return minval == maxval?
                   minval.to!string:
                   text("between ", minval, " and ", maxval);
        }

        auto Matches(Num n) const {
            return n >= minval && n <= maxval;
        }
    }

    alias Range = ValRange!Num;
    Range[] vranges;

    auto MergeRanges() {
        if (vranges.length < 2)
            return;

        Range[] settled = [vranges[0]];
        foreach (const ref vr; vranges[1..$])
            if (!settled[$-1].MergeWith(vr))
                settled ~= vr;

        vranges = settled;
    }

protected:
    this(in string name, Num *p_receiver, Indicator *p_indicator, in Num dfault) {
        super(name, true, p_indicator, p_receiver, dfault);
    }

    final AddRangeRaw(in Num min, in Num max) {
        vranges ~= Range(min, max);
        sort(vranges);
        MergeRanges;
    }

    abstract Num ParseNumber(const(char)[] aarg) const;

    final override Num Parse(in char[] aarg, in InvokedBy invocation) {
        Num result = void;
        try
            result = ParseNumber(aarg);
        catch (Exception e)
            throw new ParseException("Invalid argument for ", DescribeArgumentForError(invocation), ": ", aarg);

        return result;
    }

    final RangeErrorMessage(in InvokedBy invocation) const {
        assert(!vranges.empty);
        string result = "The argument for " ~ DescribeArgumentForError(invocation) ~ " must be ";
        foreach (uint index, const ref vr; vranges) {
            result ~= vr.toString;
            const remaining = cast(uint) vranges.length - index - 1;
            if (remaining > 1)
                result ~= ", ";
            else if (remaining == 1)
                result ~= " or ";
        }

        return result;
    }

    final override string ViolatesConstraints(in Num n, in InvokedBy invocation) {
        return
            vranges.empty?                      null:
            vranges.any!(vr => vr.Matches(n))?  null:
                                                RangeErrorMessage(invocation);
    }
}

// short, ushort, int, uint, etc:

/++
 + By calling Pos() or Named() with an integral member variable, your program
 + creates an instance of (some template specialisation of) class IntegralFArg.
 + This class has methods governing the way numbers are interpreted and the
 + range of values your program is willing to accept.
 +/

class IntegralFArg(Num): NumericFArgBase!(Num, 1) if (isIntegral!Num && !is(Num == enum)) {
private:
    alias Radix = uint;
    Radix def_radix = 10;

protected:
    final override Num ParseNumber(const(char)[] aarg) const {
        auto radices = ["0b": 2u, "0o": 8u, "0n": 10u, "0x": 16u];
        Radix radix = def_radix;
        if (aarg.length > 2)
            if (const ptr = aarg[0..2] in radices) {
                radix = *ptr;
                aarg = aarg[2..$];
            }

        return aarg.to!Num(radix);
    }

public:
    mixin CanSetSpecialDefaults;

    this(in string name, Num *p_receiver, Indicator *p_indicator, in Num dfault) {
        super(name, p_receiver, p_indicator, dfault);
    }

    /++
     + The AddRange() methods enable you to specify any number of valid ranges
     + for the user's input.  If you specify two or more overlapping or adjacent
     + ranges (in any order), Argon will amalgamate them when displaying error
     + messages.  If you specify a default value for your argument, it can
     + safely lie outside all the ranges you specify; testing for a value
     + outside the permitted space is one way to test whether the user specified
     + a number explicitly or relied on the default.
     +
     + The first overload adds a single permissible value.
     +/

    final AddRange(in Num n) {
        AddRangeRaw(n, n);
        return this;
    }

    /// The second overload adds a range of permissible values.

    final AddRange(in Num min, in Num max) {
        AddRangeRaw(min, max);
        return this;
    }

    /++
     + The default radix for integral number is normally decimal; the user can
     + specify `0b`, `0o` or `0x` to have Argon parse integral numbers in
     + binary, octal or hex.  (A leading zero is not enough to force
     + interpretation in octal.)
     +
     + SetDefaultRadix() can changes the default radix to binary, octal or hex
     + (or, indeed, back to decimal); a user wishing to specify numbers in
     + decimal when that's not the default base must use a `0n` prefix.
     +
     + Use this facility sparingly and document its use clearly.  It's easy to
     + take users by surprise.
     +/

    final SetDefaultRadix(in uint dr) {
        def_radix = dr;
        return this;
    }
}

@system unittest {
    alias InvokedBy = FArgBase.InvokedBy;
    alias IntArg    = IntegralFArg!int;
    alias Range     = IntArg.Range;

    int target;
    Indicator seen;
    auto ia0 = new IntArg("fred", &target, &seen, 5);
    assert(target == target.init);
    assert(seen == Indicator.NotSeen);
    assert(ia0.vranges.empty);

    assert(!ia0.HasShortName);
    ia0('f');
    assert(ia0.HasShortName);
    assert(ia0.GetShortName == 'f');

    ia0.See("8", InvokedBy.LongName);
    assert(seen == Indicator.Seen);
    assert(target == 8);

    ia0.AddRange(50, 59);
    assert(ia0.vranges == [Range(50, 59)]);
    ia0.AddRange(49);
    assert(ia0.vranges == [Range(49, 59)]);
    ia0.AddRange(60);
    assert(ia0.vranges == [Range(49, 60)]);
    ia0.AddRange(70, 75);
    assert(ia0.vranges == [Range(49, 60), Range(70, 75)]);
    ia0.AddRange(42, 44);
    assert(ia0.vranges == [Range(42, 44), Range(49, 60), Range(70, 75)]);
    ia0.AddRange(45, 47);
    assert(ia0.vranges == [Range(42, 47), Range(49, 60), Range(70, 75)]);
    ia0.AddRange(48);
    assert(ia0.vranges == [Range(42, 60), Range(70, 75)]);

    ia0.AddRange(20, 24);
    ia0.AddRange(100);
    foreach (i; [20, 24, 42, 60, 70, 75, 100])
        assert(ia0.ViolatesConstraints(i, InvokedBy.LongName) is null);

    foreach (i; [19, 25, 41, 61, 69, 76, 99, 101]) {
        immutable error = ia0.ViolatesConstraints(i, InvokedBy.LongName);
        assert(error == "The argument for the --fred option must be between 20 and 24, between 42 and 60, between 70 and 75 or 100", "Error was: " ~ error);
    }

    auto ia1 = new IntArg("françoise", &target, null, 5);

    foreach (radix, val; [2:4, 8:64, 10:100, 16:256]) {
        ia1.SetDefaultRadix(radix);
        ia1.See("100", InvokedBy.LongName);
        assert(target == val);

        foreach (str, meaning; ["0b100":4, "0o100":64, "0n100":100, "0x100":256]) {
            ia1.See(str, InvokedBy.LongName);
            assert(target == meaning);
        }
    }

    try {
        ia1.See("o", InvokedBy.LongName);
        assert(false);
    }
    catch (ParseException x)
    assert(x.msg == "Invalid argument for the --françoise option: o", "Message was: " ~ x.msg);
}


// float, double, real:

/++
 + By calling Pos() or Named() with a floating-point member variable, your
 + program creates an instance of (some template specialisation of) class
 + FloatingFArg.  Like IntegralFArg, FloatingFArg enables you to limit the range
 + of numbers your program will accept.  There is no provision, however, for
 + users to specify floating point numbers in radices other than 10.
 +/

class FloatingFArg(Num): NumericFArgBase!(Num, 0.0) if (isFloatingPoint!Num) {
    mixin CanSetSpecialDefaults;

    this(in string name, Num *p_receiver, Indicator *p_indicator, in Num dfault) {
        super(name, p_receiver, p_indicator, dfault);
    }

protected:
    final override Num ParseNumber(const(char)[] aarg) const {
        return aarg.to!Num;
    }

public:
    /++
     + AddRange() enables you to specify any number of valid ranges
     + for the user's input.  If you specify two or more overlapping or touching
     + ranges (in any order), Argon will amalgamate them when displaying error
     + messages.  If you specify a default value for your argument, it can
     + safely lie outside all the ranges you specify; testing for a value
     + outside the permitted space is one way to test whether the user specified
     + a number explicitly or relied on the default.
     +/
    final AddRange(in Num min, in Num max) {
        AddRangeRaw(min, max);
        return this;
    }
}

@system unittest {
    alias InvokedBy = FArgBase.InvokedBy;
    alias DblArg    = FloatingFArg!double;
    alias Range     = DblArg.Range;

    double receiver;
    Indicator indicator;
    auto da0 = new DblArg("fred", &receiver, &indicator, double.init);
    assert(da0.ViolatesConstraints(0.0, InvokedBy.ShortName) is null);

    da0.AddRange(1, 2);
    da0.AddRange(0, 1);
    assert(da0.vranges == [Range(0, 2)]);

    da0.AddRange(3.5, 4.25);
    assert(da0.vranges == [Range(0, 2), Range(3.5, 4.25)]);

    foreach (double f; [0, 1, 2, 3.5, 4.25])
        assert(da0.ViolatesConstraints(f, InvokedBy.LongName) is null);

    foreach (f; [-0.5, 2.5, 3.0, 4.5]) {
        immutable error = da0.ViolatesConstraints(f, InvokedBy.LongName);
        assert(error == "The argument for the --fred option must be between 0 and 2 or between 3.5 and 4.25", "Error was: " ~ error);
    }
}

// Enumerations:

class EnumeralFArg(E): HasReceiver!E if (is(E == enum)) {
private:
    E *p_receiver;
    E dfault;

protected:
    final override E Parse(in char[] aarg, in InvokedBy invocation) {
        uint nr_found;
        E result;
        foreach (val; EnumMembers!E) {
            const txt = text(val);
            if (txt.startsWith(aarg)) {
                result = val;
                if (txt.length == aarg.length)
                    // 'bar' isn't ambiguous if the available values are 'bar'
                    // and 'barfly':
                    return val;

                ++nr_found;
            }
        }

        if (nr_found == 0)
            throw new ParseException('\'', aarg, "' is not a permitted value for ",
                                     DescribeArgumentForError(invocation),
                                     "; permitted values are ", RenderValidOptions(""));

        if (nr_found > 1)
            throw new ParseException("In ", DescribeArgumentForError(invocation), ", '", aarg,
                                     "' is ambiguous; permitted values starting with those characters are ",
                                     RenderValidOptions(aarg));

        return result;
    }

public:
    mixin CanSetSpecialDefaults;

    this(in string name, E *p_receiver, Indicator *p_indicator, in E dfault) {
        super(name, true, p_indicator, p_receiver, dfault);
    }

    static RenderValidOptions(in char[] root) {
        return [EnumMembers!E]
                .map!(e => e.text)
                .filter!(str => str.startsWith(root))
                .join(", ");
    }
}

@system unittest {
    alias InvokedBy = FArgBase.InvokedBy;
    enum Colours {black, red, green, yellow, blue, magenta, cyan, white}
    Colours colour;
    Indicator cseen;

    alias ColourArg = EnumeralFArg!Colours;
    auto ca0 = new ColourArg("fred", &colour, &cseen, Colours.init);

    assert(!ca0.HasShortName);
    ca0('ä');
    assert(ca0.HasShortName);
    assert(ca0.GetShortName == 'ä');

    assert(ca0.RenderValidOptions("")    == "black, red, green, yellow, blue, magenta, cyan, white");
    assert(ca0.RenderValidOptions("b")   == "black, blue");
    assert(ca0.RenderValidOptions("bl")  == "black, blue");
    assert(ca0.RenderValidOptions("bla") == "black");
    assert(ca0.RenderValidOptions("X")   == "");

    enum Girls {Zoë, Françoise, Beyoncé}
    Girls girl;
    Indicator gseen;
    alias GirlArg = EnumeralFArg!Girls;
    auto ga0 = new GirlArg("name", &girl, &gseen, Girls.init);
    assert(ga0.RenderValidOptions("")    == "Zoë, Françoise, Beyoncé");
    assert(ga0.RenderValidOptions("F")   == "Françoise");

    assert(cseen == Indicator.NotSeen);
    ca0.See("yellow", InvokedBy.LongName);
    assert(colour == Colours.yellow);
    ca0.See("whi", InvokedBy.LongName);
    assert(colour == Colours.white);
    ca0.See("g", InvokedBy.LongName);
    assert(colour == Colours.green);

    foreach (offering; ["b", "bl"])
        try {
            ca0.See(offering, InvokedBy.LongName);
            assert(false);
        }
        catch (ParseException x)
            assert(x.msg == "In the --fred option, '" ~ offering ~ "' is ambiguous; permitted values starting with those characters are black, blue", "Message was: " ~ x.msg);

    ca0.See("blu", InvokedBy.LongName);
    assert(colour == Colours.blue);
    ca0.See("bla", InvokedBy.LongName);
    assert(colour == Colours.black);

    assert(gseen  == Indicator.NotSeen);
    ga0.See("Z", InvokedBy.LongName);
    assert(girl   == Girls.Zoë);
    assert(gseen  == Indicator.Seen);
    ga0.See("Françoise", InvokedBy.LongName);
    assert(girl   == Girls.Françoise);

    try {
        ga0.See("Jean-Paul", InvokedBy.LongName);
        assert(false);
    }
    catch (ParseException x)
        assert(x.msg == "'Jean-Paul' is not a permitted value for the --name option; permitted values are Zoë, Françoise, Beyoncé", "Message was: " ~ x.msg);

    // EOL defaults:
    auto ga1 = new GirlArg("name", &girl, &gseen, Girls.init);
    ga1.EolDefault(Girls.Françoise);
    ga1.SetFArgToDefault;
    assert(girl  == Girls.init);
    assert(gseen == Indicator.NotSeen);

    ga1.SeeEolDefault;
    assert(girl  == Girls.Françoise);
    assert(gseen == Indicator.UsedEolDefault);

    // Can't have an EOL default and an equals default for the same arg:
    assertThrown!AssertError(ga1.SetEqualsDefault(Girls.Zoë));

    // Equals defaults:
    auto ga2 = new GirlArg("name", &girl, &gseen, Girls.init);
    ga2.EqualsDefault(Girls.Françoise);
    ga1.SetFArgToDefault;
    assert(girl  == Girls.init);
    assert(gseen == Indicator.NotSeen);

    ga2.SeeEqualsDefault;
    assert(girl  == Girls.Françoise);
    assert(gseen == Indicator.UsedEqualsDefault);

    // Can't have an EOL default and an equals default for the same arg:
    assertThrown!AssertError(ga2.SetEolDefault(Girls.Zoë));
}

class IncrementalFArg(Num): HasReceiver!Num if (isIntegral!Num) {
public:
    this(in string name, Num *pr) {
        super(name, false, null, pr, Num.init);
        MarkIncremental;
    }

    override void See() {
        ++*p_receiver;
    }

    override Num Parse(const char[], const InvokedBy) {
        return Num.init;
    }
}

// strings:

// struct Regex won't tolerate being instantiated with a const or immutable
// character type.  Given an arbitrary string type, we must therefore find the
// element type and strip it of `const' and `immutable'.

template BareCharType(Str) {
    // Find the qualified element type:
    template ElementType(Str: Chr[], Chr) {
        alias ElementType = Chr;
    }

    // Result: element type without qualifiers:
    alias BareCharType = Unqual!(ElementType!Str);
}

// This class holds one regex and error message, which will be applied to an
// actual string argument at runtime.

class ArgRegex(Char) {
private:
    alias Caps    = Captures!(Char[]);
    alias AllCaps = Caps[];
    alias Str     = const Char[];

    Regex!Char rx;
    string error_msg;
    bool snip;

    static Interpolate(in string msg, AllCaps *p_allcaps) {
        if (!p_allcaps)
            return msg;

        // Receives a string of the form "{2:PORT}".
        // Returns p_allcaps[2]["PORT"].
        auto look_up_cap(Captures!string caps) {
            immutable rx_no = caps[1].to!uint;
            assert(rx_no < p_allcaps.length, "The format {" ~ caps[1] ~ ':' ~ caps[2] ~ "} refers to too high a regex number");
            auto old_caps = (*p_allcaps)[rx_no];
            const cap_name = caps[2];
            return old_caps[cap_name];
        }

        static rx  = ctRegex!(`\{ (\d+) : (\S+?) \}`, "x");
        return replaceAll!look_up_cap(msg, rx);
    }

public:
    this(in Str rxtext, in string flags, in string err) {
        rx        = regex(rxtext, flags);
        error_msg = err;
    }

    auto MakeSnip() {
        assert(!snip, "Duplicate call to Snip()");
        snip = true;
    }

    auto FailsToMatch(ref Char[] aarg, AllCaps *p_allcaps) {
        auto caps = aarg.matchFirst(rx);
        if (!caps)
            return Interpolate(error_msg, p_allcaps);

        if (p_allcaps)
            *p_allcaps ~= caps;

        if (snip)
            aarg = caps.post;

        return null;
    }
}

/++
 + By calling Pos() or Named() with string member variable, your program
 + creates an instance of (some template specialisation of) class
 + StringFArg.  This class enables you to set the minimum and maximum lengths
 + of the input your program will accept.
 +/

class StringFArg(Str): HasReceiver!Str if (isSomeString!Str) {
private:
    alias Char    = BareCharType!Str;
    alias ARx     = ArgRegex!Char;
    alias Caps    = Captures!(Char[]);
    alias AllCaps = Caps[];

    size_t min_len = 0;
    size_t max_len = size_t.max;
    ARx[] regexen;
    AllCaps *p_allcaps;

public:
    mixin CanSetSpecialDefaults;

    this(in string name, Str *p_receiver, Indicator *p_indicator, in Str dfault) {
        super(name, true, p_indicator, p_receiver, dfault.to!Str);
    }

    /++
     + Sets the minimum and maximum length of the input, in characters, that
     + your program will accept for this argument.  You can call
     + SetMinimumLength and SetMaximumLength in either order, but the code
     + asserts that the maximum is no smaller than the minimum.  By default, no
     + length restriction is applied.
     +/

    final SetMinimumLength(in size_t min)
    in {
        assert(min <= max_len);
    }
    body {
        min_len = min;
        return this;
    }

    /// ditto

    final SetMaximumLength(in size_t max)
    in {
        assert(max >= min_len);
    }
    body {
        max_len = max;
        return this;
    }

    /// Sets both the minimum and the maximum length in a single operation.

    final LimitLength(in size_t min, in size_t max)
    in {
        assert(max >= min);
    }
    body {
        min_len = min;
        max_len = max;
        return this;
    }

    /++
     + You can apply one or more regexes to the user's input.  These regexes are
     + applied in order; if any regex doesn't match, the associated error
     + message is displayed and Argon throws a ParseException.
     +
     + A typical user won't understand regexes or a message saying that a regex
     + doesn't match, so use several regexes, each more specific than the last
     + or looking further into the string than the last, and provide error
     + messages in plain language.  See the sample code below.
     +/
 
    auto AddRegex(in Str regex_code, in string regex_flags, in string error_message) {
        regexen ~= new ARx(regex_code, regex_flags, error_message);
        return this;
    }

    /++
     + When you have validated the early part of the string and want to move on
     + to the next part, you can call Snip(), which makes subsequent regexes
     + see only the part of the input that follows the most recent match.
     + Snipping avoids the need to keep rematching the early part of the string
     + once you've proved that it's valid.
     +/

    auto Snip() {
        assert(!regexen.empty, "You must call AddRegex() before calling Snip()");
        regexen[$-1].MakeSnip;
        return this;
    }

    /++
     + You can use named captures in your regexes and store the results in an
     + an array.  Each element of this array stores all the named and numbered
     + captures from a single regex.  If you store captures, a later error
     + message can refer back to an earlier successful match: for example, in
     + this code sample, `{0:PORT}` refers to the named `PORT` capture in the
     + zeroth successful match.
     + ----
     + class MyHandler: argon.Handler {
     +     string port;
     +     Captures!(char[])[] port_captures;
     +
     +     this() {
     +         Named("port-name", port, "")   // Ethernet or aggregate port name: / ^ (?: eth | agg ) \d{1,3} $ /x
     +             .AddRegex(` ^ (?P<TYPE> eth | agg ) (?! \p{alphabetic} ) `, "x", "The port name must begin with 'eth' or 'agg'")                           .Snip
     +             .AddRegex(` ^ (?P<NUMBER> \d{1,3} ) (?! \d )             `, "x", "The port type ('{0:TYPE}') must be followed by one, two or three digits").Snip
     +             .AddRegex(` ^ $                                          `, "x", "The port name ('{0:TYPE}{1:NUMBER}') mustn't be followed by any other characters")
     +             .StoreCaptures(port_captures);
     +         // ...
     +     }
     +
     +     auto Run(immutable(string)[] args) {
     +         Parse(args);
     +     }
     + }
     + ----
     + The regexes are matched in order.  If the user's input doesn't start
     + with `eth` or `agg`, the first error message is displayed.  If the input
     + starts with `eth` or `agg` but doesn't contain any numbers, the second
     + message is displayed -- but the text `{0:TYPE}` is replaced with whatever
     + the first regex captured.
     +
     + If the user provides a valid port name of, say, `agg4` then, after the
     + parse, all the following will be true:
     + ----
     + port_name                          == "agg4"
     + port_captures[0]["TYPE"]           == "agg"
     + port_captures[1]["NUMBER"].to!uint == 4
     + ----
     + If the user supplies invalid input, Argon throws a ParseException and the
     + values of `port_name` and `port_captures` are undefined.
     +/

    @trusted auto StoreCaptures(ref AllCaps ac) {
        // @trusted because we take the address of ac
        p_allcaps = &ac;
        return this;
    }

protected:
    final override Str Parse(in char[] aarg, in InvokedBy) {
        return aarg.to!Str;
    }

    final override string ViolatesConstraints(in Str str, in InvokedBy invocation) {
        const len = str.length;
        if (len < min_len)
            return text("The argument to ", DescribeArgumentForError(invocation), " must be at least ", min_len, " characters long");
        else if (len > max_len)
            return text("The argument to ", DescribeArgumentForError(invocation), " must be at most ",  max_len, " characters long");

        if (p_allcaps)
            p_allcaps.length = 0;

        if (!regexen.empty) {
            auto mutable_str = str.to!(Char[]);
            foreach (rx; regexen)
                if (auto error_msg = rx.FailsToMatch(mutable_str, p_allcaps))
                    return error_msg;
        }

        return null;
    }
}

@system unittest {
    alias StrFArg   = StringFArg!(char[]);
    char[] receiver, dfault;
    Indicator indicator;
    with (new StrFArg("fred", &receiver, &indicator, dfault)) {
        assert(indicator == Indicator.NotSeen);

        See("", InvokedBy.LongName);
        assert(indicator == Indicator.Seen);
        assert(receiver == "");

        See("Extrinsic", InvokedBy.LongName);
        assert(receiver == "Extrinsic");

        See("café", InvokedBy.LongName);
        assert(receiver == "café");
    }

    // Regular expressions:
    void test_regexen(Char, Str) () {
        Captures!(Char[])[] captures;
        Str receiver;

        with (new StringFArg!Str("fred", &receiver, &indicator, "".to!Str)
                    .AddRegex(` ^ (?P<TYPE> eth | agg ) (?! \p{alphabetic} )`, "x", "The port name must start with 'eth' or 'agg'")
                    .AddRegex(` ^ (?P<TYPE> eth | agg )                  `,    "x", "(Checking that the string doesn't change when we don't snip)")           .Snip
                    .AddRegex(` ^ (?P<NUMBER> \d{1,3} ) (?! \d          )`,    "x", "The port type ('{0:TYPE}') must be followed by one, two or three digits").Snip
                    .AddRegex(`^$`,                                            "x", "The port name must contain only 'eth' or 'agg' followed by one, two or three digits")
                    .StoreCaptures(captures)) {

            immutable invocation = InvokedBy.ShortName;
            assert(ViolatesConstraints("asdfg",   invocation) == "The port name must start with 'eth' or 'agg'");
            assert(ViolatesConstraints("aggie",   invocation) == "The port name must start with 'eth' or 'agg'");
            assert(ViolatesConstraints("eth",     invocation) == "The port type ('eth') must be followed by one, two or three digits");
            assert(ViolatesConstraints("eth4100", invocation) == "The port type ('eth') must be followed by one, two or three digits");
            assert(ViolatesConstraints("eth410?", invocation) == "The port name must contain only 'eth' or 'agg' followed by one, two or three digits");

            assert(ViolatesConstraints("agg291",  invocation) is null);
            assert(captures.length               == 4);
            assert(captures[0]["TYPE"]           == "agg");
            assert(captures[1]["TYPE"]           == "agg");
            assert(captures[2]["NUMBER"].to!uint == 291);
        }
    }

    test_regexen!(char,  string)  ();
    test_regexen!(wchar, wstring) ();
    test_regexen!(dchar, dstring) ();
}

// An argument representing a file that needs to be opened.
//
// The caller wants to express a default as a string, not as a ready-opened
// file.  Therefore, this class can't inherit from HasReceiver!File, because
// that would provide functionality relating to a default File, not a default
// filename.  So it chooses to inherit directly from HasReceiver's base and
// to reimplement the bits of HasReceiver that it needs.

/++
 + Calling Named() or Pos() with a File argument creates a FileFArg.
 +/

class FileFArg: FArgBase {
private:
    const string open_mode;
    string filename, dfault, special_default;
    string *p_error;
    File *p_receiver;

    auto OpenOrThrow(in string name) {
        *p_receiver = File(name, open_mode);
    }

    auto OpenRobustly(in string name) {
        *p_error = "";
        try
            OpenOrThrow(name);
        catch (Exception x) {
            *p_error = x.msg;
            *p_receiver = File();
        }
    }

public:
    this(in string option_name, File *pr, Indicator *p_indicator, in string mode, string *pe, in string df) {
        super(option_name, true, p_indicator);
        open_mode  = mode;
        dfault     = df;
        p_error    = pe;
        p_receiver = pr;
    }

    /++
     + Sets the default valuefor use if a named argument appears at the end of
     + the command line without an attached value.  Must not be empty.
     +
     + An end-of-line default of "-" is useful for producing optional output
     + that goes to stdout unless the user specifies an alternative destination.
     + For example:
     + ----
     + class MyHandler: argon.Handler {
     +     File file;
     +     argon.Indicator opened_file;
     +
     +     this() {
     +         Named("list", file, "wb", opened_file, null).EolDefault("-");
     +     }
     +
     +     // ...
     + }
     + ----
     + Suppose your program is called `foo`.
     + $(UL $(LI If the user runs `foo` with no
     + command line arguments, no file is opened and `opened_file` equals
     + `Indicator.NotSeen`.)
     + $(LI If the user runs `foo --list` then `file` will be a copy of `stdout`
     + and `opened_file` will equal `Indicator.UsedEolDefault`.)
     + $(LI If the user runs `foo --list saved.txt` then `file` will have an
     + open handle to `saved.txt` and `opened_file` will equal `Indicator.Seen`.
     + If `saved.txt` can't be opened, Argon will propagate the exception
     + thrown by `struct File`.))
     +/

    auto EolDefault(in string ed) {
        assert(!ed.empty,         "The end-of-line default filename can't be empty");
        assert(IsNamed,           "Only a named option can have an end-of-line default; for a positional argument, use an ordinary default");
        assert(!HasEqualsDefault, "No argument can have both an equals default and and end-of-line default");
        special_default = ed;
        MarkEolDefault;
        return this;
    }

    auto EqualsDefault(in string ed) {
        assert(!ed.empty,      "The equals default filename can't be empty");
        assert(IsNamed,        "Only a named option can have an equals default; for a positional argument, use an ordinary default");
        assert(!HasEolDefault, "No argument can have both an equals default and and end-of-line default");
        special_default = ed;
        MarkEqualsDefault;
        return this;
    }

    final override void See(in string aarg, in InvokedBy invocation) {
        if (aarg.empty)
            throw new ParseException("An empty filename isn't permitted for ", DescribeArgumentForError(invocation));

        filename = aarg;
        MarkSeen;
    }

    final override void SeeEolDefault() {
        filename = special_default;
        MarkSeenWithEolDefault;
    }

    final override void SeeEqualsDefault() {
        filename = special_default;
        MarkSeenWithEqualsDefault;
    }

    final override void SetFArgToDefault() {
        filename = dfault;  
        MarkUnseen;
    }

    // This method is called after all aargs have been seen.  This is the point
    // at which the FileFArg can open either the file specified by the user or
    // the default file specified by the caller, as appropriate.

    @trusted final override void Transform() {
        // This method has to be @trusted because otherwise:
        // Error: safe function 'Transform' cannot access __gshared data 'stdin'
        // As elsewhere, I'm open to debate about whether I've given away safety
        // too easily here.  One alternative to explore would be something like
        // my_file.fdopen(STDOUT_FILENO), but that would require importing
        // unistd.d and wouldn't even compile beyond the home fires of Posix.
        // Besides, buffering would get in the way if we had both the real
        // stdout and a private File object, both writing to the same FD from
        // different threads.

        immutable name = HasBeenSeen? filename: dfault;
        if (name.empty) {
            *p_receiver = File();
            return;
        }

        if (name == "-") {
            if (open_mode.startsWith('r')) {
                *p_receiver = stdin;
                return;
            }

            if (open_mode.startsWith('w')) {
                *p_receiver = stdout;
                return;
            }

            // If the mode is something we don't recognise it, treat the "-"
            // filename non-magically, so that struct File can throw an
            // exception for the mode string if it's really bogus.  This
            // decision also sidesteps the question of what opening stdout for
            // appending might mean.
        }

        if (p_error)
            OpenRobustly(name);
        else
            OpenOrThrow(name);
    }
}    

@system unittest {
    import std.file;
    alias InvokedBy = FArgBase.InvokedBy;

    auto test_fragile_success(in string filename) {
        File file;
        assert(!file.isOpen);
        auto fa = new FileFArg("file", &file, null, "rb", null, "");
        fa.See(filename, InvokedBy.LongName);
        fa.Transform;
        assert(file.isOpen);
    }

    auto test_robust_success(in string filename) {
        File file;
        assert(!file.isOpen);
        string error_msg;
        auto fa = new FileFArg("file", &file, null, "rb", &error_msg, "");
        fa.See(filename, InvokedBy.LongName);
        fa.Transform;
        assert(file.isOpen);
        assert(error_msg.empty);
    }

    auto test_success(in string filename) {
        assert(filename.exists, "unittest block has assumed that file " ~ filename ~ " exists; it doesn't.  The bug is in the unittest block, rather than in the code under test.");
        test_fragile_success(filename);
        test_robust_success( filename);
    }

    auto test_fragile_failure(in string filename) {
        File file;
        assert(!file.isOpen);
        auto fa = new FileFArg("file", &file, null, "rb", null, "");
        try {
            fa.See(filename, InvokedBy.LongName);
            fa.Transform;
            assert(false, "FileFArg should have failed when trying to open nonexistent file " ~ filename ~ " for input");
        }
        catch (Throwable) { }

        assert(!file.isOpen);
    }

    auto test_robust_failure(in string filename) {
        File file;
        assert(!file.isOpen);
        string error_msg;
        auto fa = new FileFArg("file", &file, null, "rb", &error_msg, "");
        fa.See(filename, InvokedBy.LongName);
        fa.Transform;
        assert(!file.isOpen);
        assert(!error_msg.empty);
    }

    auto test_failure(in string filename) {
        assert(!filename.exists, "unittest block has assumed that file " ~ filename ~ " doesn't exists; but it does.  The bug is in the unittest block, rather than in the code under test.");
        test_fragile_failure(filename);
        test_robust_failure( filename);
    }

    static if (!existent_file.empty)
        test_success(existent_file);

    static if (!nonexistent_file.empty)
        test_failure(nonexistent_file);

    // Remaining tests can be carried out on all platforms, because everyone
    // supports stdin and stdout or can be made to look convincingly like it.

    auto test_std_in_or_out(in string mode, ref File expected_file) {
        File file;
        auto fa = new FileFArg("file", &file, null, mode, null, "");
        fa.See("-", InvokedBy.LongName);
        fa.Transform;
        assert(file == expected_file);
    }

    test_std_in_or_out("r", stdin);
    test_std_in_or_out("w", stdout);

    // EOL default;
    File file0;
    auto fa0 = new FileFArg("file", &file0, null, "r", null, "");
    assert(!fa0.HasEolDefault);
    assert(!fa0.HasEqualsDefault);
    assert(!file0.isOpen);
    fa0.EolDefault("-");
    assert(fa0.HasEolDefault);
    assert(!fa0.HasEqualsDefault);
    assert(!file0.isOpen);
    fa0.SeeEolDefault;
    fa0.Transform;
    assert(file0.isOpen);
    assert(file0 == stdin);

    // A single arg can't have special defaults of both kinds:
    assertThrown!AssertError(fa0.EqualsDefault("-"));

    // Equals default:
    File file1;
    auto fa1 = new FileFArg("file", &file1, null, "r", null, "");
    assert(!fa1.HasEolDefault);
    assert(!fa1.HasEqualsDefault);
    assert(!file1.isOpen);
    fa1.EqualsDefault("-");
    assert(!fa1.HasEolDefault);
    assert(fa1.HasEqualsDefault);
    assert(!file1.isOpen);
    fa1.SeeEqualsDefault;
    fa1.Transform;
    assert(file1.isOpen);
    assert(file1 == stdin);

    // A single arg can't have special defaults of both kinds:
    assertThrown!AssertError(fa1.EolDefault("-"));
}

// An argument group is an object that restricts the combinations of arguments
// that a user can specify, and fails the parse if its restriction isn't met.
//
// This is a base class for all argument groups:

class ArgGroup {
protected:
    static auto AssertAllOptional(const FArgBase[] args) {
        assert(!args.any!(arg => arg.IsMandatory), "It doesn't make sense to place a mandatory argument into an arg group");
    }

    static auto Describe(const (FArgBase)[] args) {
        string result;
        while (!args.empty) {
            if (!result.empty)
                result ~= args.length == 1? " and ": ", ";
            result ~= args[0].DescribeArgumentOptimallyForError;
            args = args[1..$];
        }

        return result;
    }

    abstract public void Check() const;
}

// This group restricts the number of arguments that can be specified:

class CountingArgGroup: ArgGroup {
private:
    immutable uint min_count, max_count;
    const (FArgBase)[] fargs;

    auto NrSeen() const {
        return cast(uint) fargs.count!(arg => arg.HasBeenSeen);
    }

    auto RejectArgCount() const {
        if (min_count == max_count)
            throw new ParseException("Please specify exactly ", min_count, " of ",                     Describe(fargs));
        else if (min_count == 0)
            throw new ParseException("Please don't specify more than ", max_count, " of ",             Describe(fargs));
        else
            throw new ParseException("Please specify between ", min_count, " and ", max_count, " of ", Describe(fargs));
    }

public:
    this(FArgBases...) (in uint min, in uint max, in FArgBase first, in FArgBase second, in FArgBases other_args) {
        assert(min <= max);

        min_count = min;
        max_count = max;
        fargs     = [first, second];
        foreach (arg; other_args)
            fargs ~= arg;

        AssertAllOptional(fargs);

        if (min == 0) {
            assert(max >  0,            "The user must be allowed to supply at least one argument");
            assert(max <  fargs.length, "This group does nothing; please specify a non-zero minimum or a lower maximum");
        }
        else
            assert(max <= fargs.length, "The maximum count is higher than the number of formal arguments you've specified");
    }

    override void Check() const {
        immutable nr_seen = NrSeen;
        if (nr_seen < min_count || nr_seen > max_count)
            RejectArgCount;
    }
}

// This group demands that the first argument be supplied if any others are
// supplied:

class FirstOrNoneGroup: ArgGroup {
private:
    const FArgBase     head;
    const (FArgBase)[] tail;

public:
    this(FArgBases...) (in FArgBase hd, in FArgBase tail1, in FArgBases more_tail) {
        head = hd;
        tail = [tail1];
        foreach (arg; more_tail)
            tail ~= arg;

        assert(!head.IsMandatory, "If the first argument in this arg group is mandatory, the arg group will do nothing");
        AssertAllOptional(tail);
    }

    override void Check() const {
        if (!head.HasBeenSeen)
            foreach (arg; tail)
                if (arg.HasBeenSeen)
                    throw new ParseException("Please don't specify ",     arg .DescribeArgumentOptimallyForError,
                                             " without also specifying ", head.DescribeArgumentOptimallyForError); 
    }
}

// This argument group insists that all the specified args be supplied if any of
// them are supplied.

class AllOrNoneGroup: ArgGroup {
private:
    const (FArgBase)[] fargs;

    auto IsViolated() const {
        bool[2] found;

        foreach (arg; fargs) {
            found[arg.HasBeenSeen] = true;
            if (found[false] + found[true] == 2)
                return true;
        }

        return false;
    }

    auto FailTheParse() const {
        immutable selection = fargs.length == 2? "both or neither": "all or none";
        throw new ParseException("Please specify either ", selection, " of ", Describe(fargs));
    }

public:
    this(FArgBases...) (in FArgBase first, in FArgBase second, in FArgBases more_args) {
        fargs = [first, second];
        foreach (arg; more_args)
            fargs ~= arg;

        AssertAllOptional(fargs);
    }

    override void Check() const {
        if (IsViolated)
            FailTheParse;
    }
}

/++
 + It's customary for users to specify options (with single or double dashes)
 + before positional arguments (which don't start with dashes).  Your program
 + can control what happens if a user specifies an option after a positional
 + argument.
 +
 + In time-honoured fashion, a command-line token consisting of a lone double
 + dash forces Argon to treat all following tokens as positional arguments,
 + even if they start with dashes.  Your program can't override this behaviour.
 +/

enum OnOptionAfterData {
    AssumeOption,           /// Treat it as an option, as Gnu's `ls(1)` does.  This is the default behaviour.
    AssumeData,             /// Treat it as a positional argument and fail if it can't be assigned.
    Fail                    /// Throw a syntax-error exception.
}

/++
 + Most programs allow single-letter options to be bundled together, so that
 + `-x -y -z 2` (where `2` is an argument to the `-z` option) can be typed more
 + conveniently as `-xyz2`.  Your program can disable bundling, as some authors
 + prefer to, but users still won't gain the ability to specify long names with
 + a single dash, and so there's little to be said for doing so.
 +/

enum CanBundle {
    No,                     /// Insist on `-x -y -z2`.
    Yes                     /// Allow `-xyz2`.  This is the default behaviour.
}

/++
 + If your program uses Argon to handle options but then accepts an arbitrarily
 + long list of, say, filenames, you'll want Argon to hand back any tokens typed
 + by the user that can't be matched to the arguments in your code.  In most
 + cases, though, you'll want parsing to fail if the user types in unrecognised
 + arguments.
 +
 + Because Argon offers first-class treatment of positional parameters -- those
 + that aren't preceded by a `--switch-name` -- most programs never need to
 + inspect `argv` and should accept the default behaviour.
 +
 + Note that unrecognised tokens resembling options -- i.e. those starting with
 + a dash, unless a double-dash end-of-options token has appeared earlier --
 + will always fail the parse and can never be passed back to the caller.  Only
 + tokens resembling positional arguments can be passed back. 
 +/

enum PassBackUnusedAArgs {  // That spelling is deliberate
    No,                     /// Fail the parse if the user supplies unexpected arguments.  This is the default behaviour.
    Yes                     /// Pass any unexpected positional arguments back to the caller, after removing any that Argon managed to process.
}

/++
 + class Handler provides methods enabling you to specify the arguments that
 + your program will accept from the user, and it parses them at runtime.  You
 + can use it in one of two ways:
 +
 + $(UL $(LI You can write a class that inherits from Handler and calls its
 + methods directly, as in the Synopsis above;)
 + $(LI You can create a bare Handler directly and call its methods.))
 +
 + The first is preferable, because it takes care of variable lifetimes for you:
 + if your derived class calls Pos(), Named() and Incremental(), passing
 + references to its own data members, then there's no danger of calling Parse()
 + after those data members have gone away.
 +
 + After calling Pos(), Named() and Incremental() once for each argument that
 + it wishes to accept, your program can apply non-default values of
 + OnOptionAfterData and CanBundle (if you don't like the recommended defaults).
 + It then calls Parse().
 +/

// A command handler sets up FArgs and parses lists of AArgs:

class Handler {
private:
    FArgBase[] fargs;
    OnOptionAfterData opad;
    CanBundle can_bundle = CanBundle.Yes;
    PassBackUnusedAArgs pass_back;
    ArgGroup[] arg_groups;
    bool preserve;

    // Determine which FArg class to use for a given receiver type.  Ignore
    // BoolFArg, because that doesn't take an AArg and is handled separately.
    template FindFargType(T) {
        static if (is(T == enum))
            alias FindFargType = EnumeralFArg!T;
        else static if (isIntegral!T)
            alias FindFargType = IntegralFArg!T;
        else static if (isFloatingPoint!T)
            alias FindFargType = FloatingFArg!T;
        else static if (isSomeString!T)
            alias FindFargType = StringFArg!T;
        else
            static assert(false);       // The caller passed a bad receiver type
    }

    // Mark the most recently-added FArg as positional:
    auto MarkPositional()
    in {
        assert(!fargs.empty);
        assert(!fargs[$-1].IsPositional);
    }
    body {
        fargs[$-1].MarkPositional;
    }

    // In most applications, once command-line arguments have been parsed, this
    // object's state can safely be discarded.

    auto FreeMemory() {
        if (!preserve)
            arg_groups.length = fargs.length = 0;
    }

    // Assert that the caller hasn't tried to set up a mandatory positional arg
    // after an optional positional arg, because that would require the
    // first (optional) arg to become mandatory in order to satisfy the
    // requirement for the second (mandatory) arg to be specified.

    auto AssertNoOptionalPositionalParameters() const {
        assert(! fargs.any!(arg => arg.IsPositional && !arg.IsMandatory),
               "A mandatory positional argument can't follow an optional positional argument on the command line");
    }

    // A positional parameter has only one name, which mustn't include pipe
    // symbols (|).

    static AssertNoPipeSymbols(in string name) {
        assert(name.find('|').empty, "A positional parameter has only one name, which mustn't include pipe symbols (|)");
    }

public:
    /++
     + Gives your program a named Boolean argument with a default value, which
     + can be true or false.  The argument will take the non-default value if
     + the user types in the switch _name at runtime -- unless the user supplies
     + one of the six special syntaxes `--option=no`, `--option=false`,
     +`--option=0`, `--option=yes`, `--option=true` or `--option=1`, in which
     + case the argument will take the value that the user has specified,
     + regardless of the default.  Note the equals sign: an explicit Boolean
     + argument, unlike parameters of other types, can't be separated from its
     + option _name by whitespace.  The tokens `no`, `false`, `yes` and `true`
     + can be abbreviated.
     +
     + In common with all Named() methods below, this method accepts non-Ascii
     + switch names.
     +
     + The user can use any unambiguous abbreviation of the option _name.  If
     + you wish to provide a single-character short _name, call Short() or
     + opCall(char).
     +
     + What are named and positional arguments?  Consider the Gnu Linux command
     + `mkfs --verbose -t ext4 /dev/sda2`.  This command has one Boolean option
     + (`--verbose`), one string argument (`-t ext4`) and one positional
     + argument (`/dev/sda2`).  Unlike Getopt, Argon collects positional
     + argument from `argv`, checks them, converts them and stores them in
     + type-safe variables, just as it does for named arguments.
     +
     + Don't be overwhelmed by the number of overloads of Named() and Pos().
     + The rules are as follows:
     + $(UL $(LI A Boolean argument is always named and optional, even if you
     + don't specify a default value.)
     + $(LI Any other argument is optional if you provide a default value or an
     + indicator, or mandatory otherwise.)
     + $(LI `File` arguments have separate Named() and Pos() calls so that
     + you can specify an open mode and a failure protocol.))
     +/

    // Add a named Boolean argument:
    @trusted final Named(Bool) (in string name, ref Bool receiver, in bool dfault) if (is(Bool == bool)) {
        // These methods can't be formally @safe (although they are *safe*)
        // because they appear to take the address of a local variable.  They
        // don't really, because `receiver' is a reference, and so taking its
        // address is morally equivalent to passing it in by pointer, but with
        // smoother syntax.  Therefore, these methods can be @trusted.
        //
        // I could be argued out of this position, because my use of @trusted
        // seems to give @safe code a way to take a pointer to a local without
        // hitting the tripwire, and there are sound reasons why @safe code
        // doesn't want to do that.  If a class passes reference to its own
        // member vars, @trusted won't introduce any new problems, because the
        // only way you could write to the vars concerned after they'd been GCed
        // would be to call Parse() on an object that no longer existed.  If
        // you did that, you'd already be in deep trouble.  However, guarding
        // against ifs and maybes is just what @safe is for.

        auto arg = new BoolFArg(name, &receiver, dfault);
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program a named Boolean argument whose default value is
     + `false`.
     +/

    final Named(Bool) (in string name, ref Bool receiver) if (is(Bool == bool)) {
        return Named(name, receiver, bool.init);
    }

    /++
     + Gives your program an optional named argument of any type other than
     + Boolean or File, with a default value of your choice.  The user can
     + override this default value using one of two syntaxes: `--size 23` or
     + `--size=23`.  Any unambiguous abbreviation of the option _name is
     + acceptable, as in `--si 23` and `--si=23`.  If you use one of the
     + methods in FArgCommon to provide a single-character short _name, the user
     + can use additional syntaxes such as `-s 23`, `-s=23` and `-s23`.
     +/

    @trusted final Named(Arg, Dfault) (in string name, ref Arg receiver, in Dfault dfault) if (!is(Arg == bool) && !is(Arg == File)) {
        alias FargType = FindFargType!Arg;
        auto arg = new FargType(name, &receiver, null, dfault);
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program an optional named argument of any type other than
     + Boolean or File.  Instead of accepting a default value, this overload
     + expects an $(I indicator): a variable that will be set to one of the
     + values in `enum Indicator` after a successful parse, showing you whether
     + the user specified a value or not.
     +/

    @trusted final Named(Arg) (in string name, ref Arg receiver, ref Indicator indicator) if (!is(Arg == bool) && !is(Arg == File)) {
        alias FargType = FindFargType!Arg;
        auto arg = new FargType(name, &receiver, &indicator, Arg.init);
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program a mandatory named argument of any type other than
     + Boolean or File.  The user is obliged to specify this argument, or Argon
     + will fail the parse and throw a ParseException.  Unless your command has
     + a large number of argument and no obvious order in which they should be
     + specified, it's usually better to make mandatory arguments positional:
     + in other words, make users write `cp *.d backup/` rather than
     + `cp --from *.d --to backup/`.  To do this, use Pos() instead.
     +/

    @trusted final Named(Arg) (in string name, ref Arg receiver) if (!is(Arg == bool) && !is(Arg == File)) {
        alias FargType = FindFargType!Arg;
        auto arg = new FargType(name, &receiver, null, Arg.init);
        arg.MarkMandatory;
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program a mandatory named argument that opens a file.  If
     + return_error_msg_can_be_null is null, failure to open the file will
     + propagate the exception thrown by struct File; otherwise, the exception
     + will be caught and the message stored in the pointee string, and an empty
     + string indicates that the file was opened successfully.  Open modes are
     + the same as those used by `struct File`.  The user can supply the special
     + string `"-"` to mean either `stdin` or `stdout`, depending on the open
     + mode.
     +/

    @trusted final Named(Arg) (in string name, ref Arg receiver, in string open_mode, string *return_error_msg_can_be_null) if (is(Arg == File)) {
        auto arg = new FileFArg(name, &receiver, null, open_mode, return_error_msg_can_be_null, "");
        arg.MarkMandatory;
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program an optional named argument that opens a file.  The
     + indicator becomes `Indicator.UsedEolDefault`,
     + `Indicator.UsedEqualsDefault` or `Indicator.Seen` if the
     + user specifies a filename, even if the file can't be opened.
     +
     + If return_error_msg_can_be_null is null, failure to open the file will
     + propagate the exception thrown by `struct File`; otherwise, the exception
     + will be caught and the message stored in the pointee string, and an empty
     + string indicates successful opening.
     +/

    @trusted final Named(Arg) (in string name, ref Arg receiver, in string open_mode, ref Indicator indicator, string *return_error_msg_can_be_null) if (is(Arg == File)) {
        auto arg = new FileFArg(name, &receiver, &indicator, open_mode, null, "");
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program an optional named argument that opens a file.  If the
     + user doesn't specify a filename, your default filename is used instead --
     + one implication being that Argon will always try to open one file or
     + another if you use this overload.
     +
     + If return_error_msg_can_be_null is null, failure to open the file
     + (whether user-specified or default) will propagate the exception thrown
     + by struct File; otherwise, the exception will be caught and the message
     + stored in the pointee string.
     +/

    @trusted final Named(Arg) (in string name, ref Arg receiver, in string open_mode, in string dfault, string *return_error_msg_can_be_null) if (is(Arg == File)) {
        assert(!dfault.empty, "The default filename can't be empty: please use the overload that doesn't specify a default");
        auto arg = new FileFArg(name, &receiver, null, open_mode, return_error_msg_can_be_null, dfault);
        fargs ~= arg;
        return arg;
    }

    /++
     + Gives your program a mandatory positional argument of any type except
     + Boolean or File.  There are no positional or mandatory Boolean
     + arguments.
     +
     + The name you specify here is never typed in by the user: instead, it's
     + displayed in error messages when the argument is missing or the value
     + provided by the user is invalid in some way.  It should therefore be a
     + brief description of the argument (such as "widget colour").  It may
     + contain spaces.  If displayed, it will be preceded by the word "the", and
     + so your description shouldn't start with "the" or (in most cases) a
     + capital letter.
     +/

    final Pos(Arg) (in string name, ref Arg receiver) if (!is(Arg == bool) && !is(Arg == File)) {
        AssertNoOptionalPositionalParameters;
        AssertNoPipeSymbols(name);
        auto named = Named(name, receiver);
        MarkPositional;
        return named;
    }

    /++
     + Gives your program an optional positional argument of any type except
     + Boolean or File.  This overload accepts an $(I indicator): a variable
     + that will be set to one of the values of enum Indicator.
     +/

    final Pos(Arg) (in string name, ref Arg arg, ref Indicator indicator) if (!is(Arg == bool) && !is(Arg == File)) {
        AssertNoPipeSymbols(name);
        auto named = Named(name, arg, indicator);
        MarkPositional;
        return named;
    }

    /++
     + Gives your program an optional positional argument with a default value
     + of your choice and any type except Boolean or File.
     +/

    final Pos(Arg, Dfault) (in string name, ref Arg arg, in Dfault dfault) if (!is(Arg == bool) && !is(Arg == File)) {
        AssertNoPipeSymbols(name);
        auto named = Named(name, arg, dfault);
        MarkPositional;
        return named;
    }

    /++
     + Gives your program a mandatory positional argument that opens a file.  If
     + return_error_msg_can_be_null is null, failure to open the file will
     + propagate the exception thrown by struct File; otherwise, the exception
     + will be caught and the message stored in the pointee string, enabling
     + better error messages if your program opens several files.
     +/

    @trusted final Pos(Arg) (in string name, ref Arg receiver, in string open_mode, string *return_error_msg_can_be_null) if (is(Arg == File)) {
        AssertNoPipeSymbols(name);
        AssertNoOptionalPositionalParameters;
        auto named = Named(name, receiver, open_mode, return_error_msg_can_be_null);
        MarkPositional;
        return named;
    }

    /++
     + Gives your program an optional positional argument that opens a file.
     + The indicator becomes `Indicator.UsedEolDefault`,
     + `Indicator.UsedEqualsDefault` or `Indicator.Seen` if
     + the user supplies this option, even if the file can't be opened.  If
     + return_error_msg_can_be_null is null, failure to open the file will
     + propagate the exception thrown by `struct File`; otherwise, the exception
     + will be caught and the message stored in the pointee string, leaving it
     + empty if the file was opened successfully.
     +/

    @trusted final Pos(Arg) (in string name, ref Arg receiver, in string open_mode, ref Indicator indicator, string *return_error_msg_can_be_null) if (is(Arg == File)) {
        AssertNoPipeSymbols(name);
        auto named = Named(name, receiver, open_mode, indicator, return_error_msg_can_be_null);
        MarkPositional;
        return named;
    }

    /++
     + Gives your program an optional positional argument that opens a file.  If
     + the user doesn't specify a filename, your default filename is used
     + instead.  If return_error_msg_can_be_null is null, failure to open the
     + file (whether user-specified or default) will propagate the exception
     + thrown by struct File; otherwise, the exception will be caught and the
     + message stored in the pointee string.
     +
     + By adding an optional, positional File argument as the last argument on
     + your command line and giving it a default value of "-", you can do a
     + simplified version of what cat(1) does and what many Perl programs do:
     + read from a file if a filename is specified, or from stdin otherwise.
     + Argon doesn't currently support the full-blooded version of that
     + functionality, in which the user can specify any number of files at the
     + command line and your program reads from each one in turn.
     +/

    @trusted final Pos(Arg) (in string name, ref Arg receiver, in string open_mode, in string dfault, string *return_error_msg_can_be_null) if (is(Arg == File)) {
        AssertNoPipeSymbols(name);
        auto named = Named(name, receiver, open_mode, dfault, return_error_msg_can_be_null);
        MarkPositional;
        return named;
    }

    /++
     + Gives your program an incremental option, which takes no value on the
     + command line but increments its receiver each time it's specified on the
     + command line, as in `--verbose --verbose --verbose` or `-vvv`.
     +/

    @trusted final Incremental(Arg) (in string name, ref Arg receiver) if (isIntegral!Arg) {
        auto farg = new IncrementalFArg!Arg(name, &receiver);
        fargs ~= farg;
        return farg;
    }

    /++
     + We've already seen that some arguments are mandatory, some are optional
     + and a positional argument can't be specified unless all positional args
     + to its left have also been specified.  If you want to impose further
     + restrictions on which combinations of arguments, use one or more argument
     + groups.  These come in three flavours:
     + $(UL $(LI Groups that require the user to specify at least $(I N) and
     + not more than $(I M) of a given subset of your program's arguments;)
     + $(LI Groups that specify that one or more arguments can't be supplied
     + unless some other argument is also supplied; and)
     + $(LI Groups that specify that either all of a set of args must be
     + supplied or none must.))
     + Each of the following functions can accept any number of arguments
     + greater than 1, and each argument can be a member of more than one
     + argument group if you wish.  The arguments you pass to these functions
     + are returned by the Named(), Pos() and Incremental() methods.
     +
     + It doesn't make sense to place a mandatory arg into an arg group, and the
     + code will assert that you don't.
     +
     + This _first function sets up an argument group that insists that between
     + $(I N) and $(I M) of the specified arguments be supplied by the user.
     +/

    auto BetweenNAndMOf(FArgBases...) (uint min, uint max, in FArgBase first, in FArgBase second, in FArgBases more_args) {
        arg_groups ~= new CountingArgGroup(min, max, first, second, more_args);
    }

    /// Syntactic sugar.
    auto ExactlyNOf(FArgBases...) (uint n, in FArgBase first, in FArgBase second, in FArgBases more_args) {
        BetweenNAndMOf(n, n, first, second, more_args);
    }

    /// Syntactic sugar.
    auto ExactlyOneOf(FArgBases...) (in FArgBase first, in FArgBase second, in FArgBases more_args) {
        ExactlyNOf(1, first, second, more_args);
    }

    /// Syntactic sugar.
    auto AtMostNOf(FArgBases...) (uint max, in FArgBase first, in FArgBase second, in FArgBases more_args) {
        return BetweenNAndMOf(0, max, first, second, more_args);
    }

    /// Syntactic sugar.
    auto AtMostOneOf(FArgBases...) (in FArgBase first, in FArgBase second, in FArgBases more_args) {
        return BetweenNAndMOf(0, 1, first, second, more_args);
    }

    /++
     + Sets up an argment group that refuses to accept any arg in the list
     + unless the first arg is supplied by the user.
     +/

    auto FirstOrNone(FArgBases...) (in FArgBase first, in FArgBase second, in FArgBases more_args) {
        arg_groups ~= new FirstOrNoneGroup(first, second, more_args);
    }

    /++
     + Sets up an argument group that won't accept any of the arguments in the
     + list unless all of them have been supplied by the user.
     +/

    auto AllOrNone(FArgBases...) (in FArgBase first, in FArgBase second, in FArgBases more_args) {
        arg_groups ~= new AllOrNoneGroup(first, second, more_args);
    }

    /++
     + Control what happens if the user specifies an `--option` after a
     + positional parameter:
     +/

    final opCall(in OnOptionAfterData o) {
        opad = o;
    }

    /// Control whether your program allows `-xyz2` or insists on `-x -y -z2`:

    final opCall(in CanBundle cb) {
        can_bundle = cb;
    }

    /++
     + Control whether any unexpected command-line arguments should be passed
     + back to you or should cause the parse to fail.
     +/

     final opCall(in PassBackUnusedAArgs pb) {
         pass_back = pb;
     }

    /++
     + Parse a command line.  If the user's input is correct, populate
     + arguments and indicators.  Otherwise, throw a ParseException.
     +/

    final Parse(ref string[] aargs) {
        auto parser = Parser(fargs, opad, can_bundle, pass_back, arg_groups);
        parser.Parse(aargs);
        FreeMemory;
    }

    /++
     + Auto-generate a syntax summary, using names, descriptions and information
     + about whether arguments are mandatory.  To reduce clutter, the syntax
     + summary doesn't include short names or default values, both of which
     + should appear in your command's man page.
     +
     + In order to give you maximum control, arguments appear in the summary in
     + the same order as your Named(), Incremental() and Pos() calls: there's no
     + attempt to place named arguments before positional ones, which would be
     + the conventional order for users to adopt.  Therefore, if you let Argon
     + generate syntax summaries for you, you should call Named() and
     + Incremental()  before Pos() unless you have a good reason not to.  It's
     + also good style to place any mandatory named arguments before any
     + optional ones.  (With positional arguments, you don't have a choice,
     + because values are always assigned to arguments from left to right.)
     +
     + Generating a syntax summary is affordable but not trivial, so cache the
     + result if you need it more than once.
     +/

    final BuildSyntaxSummary() const {
        return fargs.filter!(farg => farg.IsDocumented)
                    .map!(farg => farg.BuildSyntaxElement)
                    .join(' ');
    }

    /++
     + Normally, class Handler saves a little memory by deleting its structures
     + after a successful parse.  If you want to be able to reuse a Handler --
     + in a unit test, perhaps -- then calling Preserve() will squelch this
     + behaviour.
     +/

    auto Preserve() {
        preserve = true;
    }
}

struct Parser {
private:
    alias InvokedBy = FArgBase.InvokedBy;

    FArgBase[] fargs;
    string[] aargs;
    string[] spilt;  // AArgs that we don't use ourselves
    immutable OnOptionAfterData opad;
    immutable CanBundle can_bundle;
    immutable PassBackUnusedAArgs pass_back;
    const ArgGroup[] arg_groups;
    bool seen_dbl_dash;
    bool seen_positional;

public:
    this(FArgBase[] f, in OnOptionAfterData o, in CanBundle cb, in PassBackUnusedAArgs pb, in ArgGroup[] ag) {
        fargs      = f;
        opad       = o;
        can_bundle = cb;
        pass_back  = pb;
        arg_groups = ag;
    }

    void Parse(ref string[] aa)
    in {
        assert(!aa.empty);
    }
    body {
        seen_dbl_dash = false;
        aargs = aa[1..$];
        SetFArgsToDefaultValues;
        ParseAllAArgs;
        InsistOnMandatoryAArgs;
        ApplyArgGroups;
        if (pass_back)
            aa = spilt;
        else if (!spilt.empty) {
            immutable any_positional = fargs.any!(farg => farg.IsPositional);
            throw new ParseException("Unexpected text: '", spilt.front, "': ",
                any_positional? "all positional arguments have been used up": "this command has no positional arguments");
        }
    }

private:
    auto SetFArgsToDefaultValues() {
        foreach (farg; fargs)
            farg.SetFArgToDefault;
    }

    auto ParseAllAArgs() {
        while (!aargs.empty)
            ParseNext();
    }

    auto MoveToNextAarg()
    in {
        assert(!fargs.empty);
    }
    body {
        aargs.popFront;
    }

    auto OpadAllowsOption() const {
        if (!seen_positional)
            return true;
        else if (opad == OnOptionAfterData.Fail)
            throw new ParseException("No --option is permitted after a positional argument");
        else
            return opad == OnOptionAfterData.AssumeOption;
    }

    auto ParseNext() {
        const aarg = aargs.front;
        if (!seen_dbl_dash) {
            if (aarg.startsWith("--") && OpadAllowsOption) {
                ParseLong;
                return;
            }
            else if (aarg.startsWith("-") && aarg.length > 1 && OpadAllowsOption) {
                ParseShort;
                return;
            }
        }

        ParseData;
    }

    auto FindUnseenNamedFarg(in string candidate) {
        auto FindFarg() {
            uint nr_results;
            FArgBase result;

            // Slight subtlety here: if the user types --col and a given FArg
            // has names --colour and --color, that isn't a conflict; but if
            // two different FArgs have names --colour and --column, that *is*
            // a conflict.
            foreach (farg; fargs)
                if (!farg.IsPositional) {
                    const names = farg.GetNames;
                    if (!names.find(candidate).empty)
                        return farg;
                    else if (names.any!(name => name.startsWith(candidate))) {
                        ++nr_results;
                        result = farg;
                    }
                }

            switch (nr_results) {
            case 0:
                throw new ParseException("This command has no --", candidate, " option");
            case 1:
                return result;
            default:
                throw new ParseException("Option name --", candidate, " is ambiguous; please supply more characters");
            }
        }

        auto farg = FindFarg;
        if (farg.HasBeenSeen)
            throw new ParseException("Please don't specify ", farg.DisplayAllNames, " more than once");

        return farg;
    }

    auto SeeLongAArg(FArgBase farg, in bool has_aarg, in string arg_name_from_user, string aarg_if_any) {
        if (has_aarg)
            farg.See(aarg_if_any, InvokedBy.LongName);
        else if (farg.HasEqualsDefault)
            farg.SeeEqualsDefault;
        else {
            MoveToNextAarg;
            if (aargs.empty) {
                if (farg.HasEolDefault) {
                    farg.SeeEolDefault;
                    return;
                }
                else {
                    // Use the full name if there's only one, or the name
                    // specified by the user (who may not be aware of some
                    // aliases) otherwise:
                    const arg_name = farg.GetNames.length == 1? farg.GetFirstName: arg_name_from_user;
                    throw new ParseException("The --", arg_name, " option must be followed by a piece of data");
                }
            }

            farg.See(aargs.front, InvokedBy.LongName);
        }

        MoveToNextAarg;
    }

    auto ParseLong() {
        const token = aargs[0][2..$];
        if (token.empty) {
            seen_dbl_dash = true;
            MoveToNextAarg;
            return;
        }

        enum Rgn {name, delim, aarg}
        const regions  = token.findSplit("=");
        bool has_delim = !regions[Rgn.delim].empty;
        auto farg      = FindUnseenNamedFarg(regions[Rgn.name]);

        if (farg.NeedsAArg)
            SeeLongAArg(farg, has_delim, regions[Rgn.name], regions[Rgn.aarg]);
        else {
            if (has_delim) {
                if (farg.IsIncremental)     // It can't accept an argument
                    throw new ParseException("The --", regions[Rgn.name], " option doesn't accept an argument");
                else                        // It's Boolean and will take an argument if it's conjoined
                    farg.See(regions[Rgn.aarg], InvokedBy.LongName);
            }
            else                            // No arg was provided, and none is needed
                farg.See;

            MoveToNextAarg;
        }
    }

    auto ParseShort() {
        auto aarg = aargs[0][1..$];
        for (;;) {
            immutable shortname = aarg.front;
            auto farg = FindUnseenNamedFarg(shortname);
            aarg.popFront;

            immutable conjoined = aarg.startsWith('=');
            if (farg.HasEqualsDefault && !conjoined)
                farg.SeeEqualsDefault;
            else if (farg.NeedsAArg) {
                SeeShortArg(farg, shortname, aarg);
                return;
            }
            else if (conjoined) {
                if (farg.IsIncremental)
                    throw new ParseException("The -", shortname, " option doesn't accept an argument");
                else {
                    farg.See(aarg[1..$], InvokedBy.ShortName);
                    break;
                }
            }
            else
                farg.See();

            if (aarg.empty)
                break;

            if (can_bundle == CanBundle.No)
                throw new ParseException("Unexpected text after -", shortname);
        }

        MoveToNextAarg;
    }

    auto FindUnseenNamedFarg(in dchar shortname) {
        foreach (farg; fargs)
            if (farg.GetShortName == shortname) {
                if (farg.HasBeenSeen)
                    throw new ParseException("Please don't specify the -", shortname, " option more than once");
                else
                    return farg;
            }

        throw new ParseException("This command has no -", shortname, " option");
    }

    auto SeeShortArg(FArgBase farg, in dchar shortname, in string aarg) {
        if (aarg.empty) {
            MoveToNextAarg;
            if (aargs.empty) {
                if (farg.HasEolDefault) {
                    farg.SeeEolDefault;
                    return;
                }
                else
                    throw new ParseException("The -", shortname, " option must be followed by a piece of data");
            }

            farg.See(aargs.front, InvokedBy.ShortName);
            MoveToNextAarg;
        }
        else {
            immutable skip_equals = aarg.front == '=';
            farg.See(aarg[skip_equals .. $], InvokedBy.ShortName);
            MoveToNextAarg;
        }
    }

    auto ParseData() {
        if (FArgBase next_farg = FindFirstUnseenPositionalFArg)
            next_farg.See(aargs.front, InvokedBy.Position);
        else
            spilt ~= aargs.front;

        seen_positional = true;
        MoveToNextAarg;
    }

    auto FindFirstUnseenPositionalFArg() {
        foreach (farg; fargs)
            if (farg.IsPositional)
                if (!farg.HasBeenSeen)
                    return farg;

        return null;
    }

    auto InsistOnMandatoryAArgs() {
        foreach (farg; fargs) {
            farg.Transform;
            if (farg.IsMandatory && !farg.HasBeenSeen)
                throw new ParseException("This command needs ", farg.DescribeArgumentOptimallyForError, " to be specified");
        }
    }

    auto ApplyArgGroups() const {
        foreach (group; arg_groups)
            group.Check;
    }
}

unittest {
    import std.math;

    enum Colours {black, red, green, yellow, blue, magenta, cyan, white}
    immutable fake_program_name = "argon";

    @safe class TestableHandler: Handler {
        auto Run(ref string[] aargs) {
            aargs = [fake_program_name] ~ aargs;
            Parse(aargs);
        }

        auto Run(string[] aargs) {
            aargs = [fake_program_name] ~ aargs;
            Parse(aargs);
        }

        auto Run(in string joined_args) {
            auto args = joined_args.split;
            Run(args);
        }

        auto FailRun(string[] aargs, in string want_error) {
            try {
                aargs = [fake_program_name] ~ aargs;
                Parse(aargs);
                assert(false, "The parse should have failed with this error: " ~ want_error);
            }
            catch (ParseException x)
                if (x.msg != want_error) {
                    writeln("Expected this error: ", want_error);
                    writeln("Got      this error: ", x.msg);
                    assert(false);
                }
        }

        auto FailRun(in string joined_args, in string want_error) {
            FailRun(joined_args.split, want_error);
        }

        auto ExpectSummary(in string expected) {
            immutable summary = BuildSyntaxSummary;
            assert(summary == expected, text("Expected:  ", expected, "\nGenerated: ", summary));
        }
    }

    @safe class Fields00: TestableHandler {
        int alpha, bravo, charlie, delta;
        double echo, foxtrot;
        Colours colour;
        char[] name, nino;
        bool turn, twist, tumble;
        Indicator got_alpha, got_bravo, got_charlie, got_delta, got_echo, got_foxtrot;
        Indicator got_colour, got_name;

        this() {
            Preserve;
        }
    }

    @safe class CP00: Fields00 {
        this() {
            // Test the long way of specifying short names:
            Named      ("alpha|able|alfie|aah", alpha,   5)        .Short('a');
            Named      ("bravo|baker",          bravo,   got_bravo).Short('b').Description("call of approbation");
            Named      ("charlie|charles",      charlie)           .Short('c');
            Incremental("delta",                delta)             .Short('d');
            Named      ("echo",                 echo,    0.0);

            ExpectSummary("[--alpha <alpha>] [--bravo <call of approbation>] --charlie <charlie> --delta* [--echo <echo>]");
        }
    }

    // Default values for int receivers and indicators:
    auto cp00 = new CP00;
    cp00.Run("--charlie=32");
    assert(cp00.alpha     == 5);
    assert(cp00.bravo     == cp00.bravo.init);
    assert(cp00.got_bravo == Indicator.NotSeen);
    assert(cp00.charlie   == 32);
    assert(cp00.delta     == 0);

    // Non-default values for int receivers and indicators:
    cp00.Run("--alpha 8 --bravo 7 --charlie 9");
    assert(cp00.alpha     == 8);
    assert(cp00.bravo     == 7);
    assert(cp00.charlie   == 9);
    assert(cp00.got_bravo == Indicator.Seen);

    // Abbreviated and short names:
    cp00.Run("--al 23 -c 17");
    assert(cp00.got_bravo == Indicator.NotSeen);
    assert(cp00.bravo     == cp00.bravo.init);
    assert(cp00.alpha     == 23);
    assert(cp00.charlie   == 17);

    // Alternative names, and abbreviated names with the same stem for the same farg:
    cp00.Run("--able 22 --cha 18");
    assert(cp00.got_bravo == Indicator.NotSeen);
    assert(cp00.bravo     == cp00.bravo.init);
    assert(cp00.alpha     == 22);
    assert(cp00.charlie   == 18);

    // Same farg used twice:
    cp00.FailRun("--alpha 4 --bravo 7 -a      8", "Please don't specify the -a option more than once");
    cp00.FailRun("--alpha 4 --bravo 7 --alpha 8", "Please don't specify the --alpha option (also known as --able and --alfie and --aah) more than once");

    // Bad long option name:
    cp00.FailRun("--alfred 4 --bravo 7 -c 8", "This command has no --alfred option");

    // Bad short name:
    cp00.FailRun("--alpha 4 --bravo 7 -Q 8", "This command has no -Q option");

    // Alternative ways of joining options and data:
    cp00.Run("-a1 --bravo=2 -c=9");
    assert(cp00.alpha     == 1);
    assert(cp00.bravo     == 2);
    assert(cp00.charlie   == 9);
    assert(cp00.got_bravo == Indicator.Seen);

    // Unexpected positional AArg:
    cp00.FailRun("--alpha 4 --charlie 7 5", "Unexpected text: '5': this command has no positional arguments");

    // Invalid argument:
    cp00.FailRun("--alpha papa", "Invalid argument for the --alpha option (also known as --able and --alfie and --aah): papa");

    // Missing required parameter.
    // --charlie has aliases, so we should see back whatever name we used:
    cp00.FailRun("--alpha 6 --bravo 7 --charlie", "The --charlie option must be followed by a piece of data");
    cp00.FailRun("--alpha 6 --bravo 7 --charles", "The --charles option must be followed by a piece of data");
    cp00.FailRun("--alpha 6 --bravo 7 --cha",     "The --cha option must be followed by a piece of data");
    cp00.FailRun("--alpha 6 --bravo 7 -c", "The -c option must be followed by a piece of data");

    // --echo has no alias, and so we we should always see back its full name:
    cp00.FailRun("--charlie 3 --echo", "The --echo option must be followed by a piece of data");
    cp00.FailRun("--charlie 3 --ec",   "The --echo option must be followed by a piece of data");

    // Positional parameter passed to a command that doesn't expect any:
    cp00.FailRun("-c0 armadillo", "Unexpected text: 'armadillo': this command has no positional arguments");

    // Incremental parameter:
    cp00.Run("--delta --charlie 13");
    assert(cp00.charlie == 13);
    assert(cp00.delta   == 1);

    cp00.Run("--delta -ddd --charlie 13");
    assert(cp00.charlie == 13);
    assert(cp00.delta == 4);

    cp00.FailRun("--charlie 33 --delta 9", "Unexpected text: '9': this command has no positional arguments");
    cp00.FailRun("--charlie 33 --delta=9", "The --delta option doesn't accept an argument");
    cp00.FailRun("--charlie 33 -d 9",      "Unexpected text: '9': this command has no positional arguments");
    cp00.FailRun("--charlie 33 -d=9",      "The -d option doesn't accept an argument");

    // Mixed-case and non-Ascii names, names that are trunks of others, and
    // the ability to enable or disable bundling:
    class CP01: Fields00 {
        this() {
            // Use the short way of specifying short names:
            Named("liberté",    alpha)   ('l');
            Named("égalité",    bravo)   ('é');
            Named("fraternité", charlie) ('f');
            Named("Fraternité", delta)   ('F').Undocumented;
            Named("abcd",       turn)    ('u');
            Named("abcde",      twist)   ('w');
            Named("abcdef",     tumble)  ('m');

            ExpectSummary("--liberté <liberté> --égalité <égalité> --fraternité <fraternité> [--abcd] [--abcde] [--abcdef]");
        }
    }

    auto cp01 = new CP01;
    cp01.Run("--liberté 4 --égalité=5 --fr 8 --F=9");
    assert(cp01.alpha   == 4);
    assert(cp01.bravo   == 5);
    assert(cp01.charlie == 8);
    assert(cp01.delta   == 9);

    cp01.Run("-l1 -é3 -F=7 -f 5");
    assert(cp01.alpha   == 1);
    assert(cp01.bravo   == 3);
    assert(cp01.charlie == 5);
    assert(cp01.delta   == 7);

    cp01.FailRun("-l1 -é3 -F=7 -f 5 --abc", "Option name --abc is ambiguous; please supply more characters");

    cp01.Run("-l1 -é3 -F=7 -f 5 --abcd");
    assert( cp01.turn);
    assert(!cp01.twist);
    assert(!cp01.tumble);

    cp01.Run("-l1 -é3 -F=7 -f 5 --abcde");
    assert(!cp01.turn);
    assert( cp01.twist);
    assert(!cp01.tumble);

    cp01.Run("-l1 -é3 -F=7 -f 5 --abcdef");
    assert(!cp01.turn);
    assert(!cp01.twist);
    assert( cp01.tumble);

    cp01.FailRun("-l1 -é3 -F=7 -f 5 --abcefg", "This command has no --abcefg option");

    // Mandatory parameters:
    cp01.FailRun("-l1 -é3 -F=7", "This command needs the --fraternité option to be specified");

    // Bundling:
    cp01.Run("-l1 -é3 -F=7 -f 5 -u");
    assert( cp01.turn);
    assert(!cp01.twist);
    assert(!cp01.tumble);

    cp01.Run("-l1 -é3 -F=7 -f 5 -um");
    assert( cp01.turn);
    assert(!cp01.twist);
    assert( cp01.tumble);

    cp01.Run("-l1 -é3 -F=7 -f 5 -umw");
    assert( cp01.turn);
    assert( cp01.twist);
    assert( cp01.tumble);

    cp01(CanBundle.No);
    cp01.Run("-l1 -é3 -F=7 -f 5 -u");
    assert( cp01.turn);
    assert(!cp01.twist);
    assert(!cp01.tumble);

    cp01.FailRun("-l1 -é3 -F=7 -f 5 -um", "Unexpected text after -u");

    // Special treatment of Boolean options:
    class CP02: Fields00 {
        this() {
            Named("turn",   turn)          ('u');
            Named("twist",  twist,  true)  ('w');
            Named("tumble", tumble, false) ('m');
        }
    }

    // Default Boolean values:
    auto cp02 = new CP02;
    cp02.Run("");
    assert(!cp02.turn);
    assert( cp02.twist);
    assert(!cp02.tumble);

    // If we just specify the bare option name, all flags should be inverted:
    cp02.Run("--turn --tw --tum");
    assert( cp02.turn);
    assert(!cp02.twist);
    assert( cp02.tumble);

    // If we specify =false or similar, all flags should go false, regardless
    // of their default values:
    cp02.Run("--turn=false --tw=0 --tum=no");
    assert(!cp02.turn);
    assert(!cp02.twist);
    assert(!cp02.tumble);

    cp02.Run("-u=false -w=0 -m=no");
    assert(!cp02.turn);
    assert(!cp02.twist);
    assert(!cp02.tumble);

    // Similarly, specifying =true or similar should make them all go true:
    cp02.Run("--turn=tr --tw=1 --tum=yes");
    assert( cp02.turn);
    assert( cp02.twist);
    assert( cp02.tumble);

    cp02.Run("-u=true -w=1 -m=yes");
    assert( cp02.turn);
    assert( cp02.twist);
    assert( cp02.tumble);

    // Any value must be attached to the option by '=', and can't follow in the
    // next token:
    cp02.FailRun("--turn yes", "Unexpected text: 'yes': this command has no positional arguments");

    // If there's a positional string argument, the 'yes' AArg should go there
    // instead:
    class CP03: CP02 {
        this() {
            Pos("name of the oojit", name, "");
        }
    }

    auto cp03 = new CP03;
    cp03.Run("--turn yes");
    assert(cp03.turn);
    assert(cp03.name == "yes");

    // Test that we can assign short names and call type-specific methods in
    // any order.  (Bad style; don't emulate.)
    class CP04: Fields00 {
        this() {
            Named("alpha", alpha, got_alpha) ('a').AddRange(0, 9).AddRange(20, 29) ("transparency");
            Named("bravo", bravo, -1)        .AddRange(0, 9) ('b').AddRange(20, 29) ("señor");
            Named("name",  name,  "")        ('n') ("nomenclature").LimitLength(1, 20);
            Named("nino",  nino,  "")        .LimitLength(9, 9).Description("national insurance number") ('i');

            ExpectSummary("[--alpha <transparency>] [--bravo <señor>] [--name <nomenclature>] [--nino <national insurance number>]");
        }
    }

    auto cp04 = new CP04;
    cp04.Run("-b 24 -n Nancy");
    assert(cp04.alpha     == cp04.alpha.init);
    assert(cp04.got_alpha == Indicator.NotSeen);
    assert(cp04.bravo     == 24);
    assert(cp04.name      == "Nancy");
    assert(cp04.nino.empty);    // The default value can have a length outside the mandated range

    cp04.Run("-a7 -iAB123456X");
    assert(cp04.alpha     == 7);
    assert(cp04.got_alpha == Indicator.Seen);
    assert(cp04.bravo     == -1);   // Again, a numeric default can lie outside the prescribed range
    assert(cp04.name.empty);
    assert(cp04.nino       == "AB123456X");

    // Positional arguments:
    class CP05: Fields00 {
        this() {
            Pos("alpha",   alpha);                  // Mandatory, because no indicator or default value is given
            Pos("bravo",   bravo,   got_bravo);     // Optional: has an indicator
            Pos("charlie", charlie, 23);            // Optional: has a default value
        }
    }

    auto cp05 = new CP05;
    cp05.Run("14");
    assert(cp05.alpha     == 14);
    assert(cp05.bravo     == cp05.bravo.init);
    assert(cp05.got_bravo == Indicator.NotSeen);
    assert(cp05.charlie   == 23);

    cp05.Run("14 39");
    assert(cp05.alpha     == 14);
    assert(cp05.bravo     == 39);
    assert(cp05.got_bravo == Indicator.Seen);
    assert(cp05.charlie   == 23);

    cp05.Run("14 39 43");
    assert(cp05.alpha     == 14);
    assert(cp05.bravo     == 39);
    assert(cp05.got_bravo == Indicator.Seen);
    assert(cp05.charlie   == 43);

    cp05.FailRun("--alpha 3", "This command has no --alpha option");

    // Mixing named and positional arguments, and passing unused arguments
    // back to the caller:
    class CP06: Fields00  {
        this() {
            Named("alpha",   alpha)               ("the première").EolDefault(23) ('a');
            Named("bravo",   bravo,   got_bravo)                  .EolDefault(22) ('b');
            Named("charlie", charlie, 11)                         .EolDefault(21) ('c');

            Named("turn",    turn);
            Named("twist",   twist);
            Named("tumble",  tumble);

            Pos  ("delta",   delta);
            Pos  ("echo",    echo,    got_echo);
            Pos  ("foxtrot", foxtrot, 5.0);

            ExpectSummary("--alpha <the première> [--bravo <bravo>] [--charlie <charlie>] [--turn] [--twist] [--tumble] <delta> [<echo>] [<foxtrot>]");
        }
    }

    auto cp06 = new CP06;
    with (cp06) {
        Run("--alpha 7 16");
        assert( alpha     == 7);
        assert( bravo     == cp06.bravo.init);
        assert( got_bravo == Indicator.NotSeen);
        assert( charlie   == 11);
        assert( delta     == 16);
        assert( echo.isNaN);
        assert( got_echo  == Indicator.NotSeen);
        assert( foxtrot   == 5.0);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("16 --alpha 7");
        assert( alpha     == 7);
        assert( bravo     == cp06.bravo.init);
        assert( got_bravo == Indicator.NotSeen);
        assert( charlie   == 11);
        assert( delta     == 16);
        assert( echo.isNaN);
        assert( got_echo  == Indicator.NotSeen);
        assert( foxtrot   == 5.0);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("16 --alpha 7 4 --bravo 9 --charlie 10 6.25");
        assert( alpha     == 7);
        assert( bravo     == 9);
        assert( got_bravo == Indicator.Seen);
        assert( charlie   == 10);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }
    cp06(OnOptionAfterData.AssumeData);
    cp06.FailRun("16 --alpha 7 4 --bravo 9 --charlie 10 6.25", "Invalid argument for the echo: --alpha");

    cp06(OnOptionAfterData.Fail);
    cp06.FailRun("16 --alpha 7 4 --bravo 9 --charlie 10 6.25", "No --option is permitted after a positional argument");

    cp06(OnOptionAfterData.AssumeOption);   // Just because that's the default state

    // Long description should be used whenever it's available:
    cp06.FailRun("--alpha piper --delta 33", "Invalid argument for the première: piper");

    // Unused arguments should be returned to the caller if requested:
    cp06(PassBackUnusedAArgs.Yes);
    auto aargs = ["--alpha", "9", /* delta: */ "1", /* echo: */ "2", "--bravo", "10", /* foxtrot: */ "3", "--charlie", "14", /* spilt: */ "hello", "--turn", /* spilt: */ "world"];
    cp06.Run(aargs);
    assert(aargs == ["hello", "world"]);
    cp06(PassBackUnusedAArgs.No);           // Return to the default state

    // End-of-line defaults:
    with (cp06) {
        Run("16 4.0 --bravo 9 --charlie 10 6.25 --alpha");
        assert( alpha     == 23);
        assert( bravo     == 9);
        assert( got_bravo == Indicator.Seen);
        assert( charlie   == 10);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("16 4.0 --bravo 9 --charlie 10 6.25 -a");
        assert( alpha     == 23);
        assert( bravo     == 9);
        assert( got_bravo == Indicator.Seen);
        assert( charlie   == 10);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("--alpha 29 16 4.0 --charlie 10 6.25 --bravo");
        assert( alpha     == 29);
        assert( bravo     == 22);
        assert( got_bravo == Indicator.UsedEolDefault);
        assert( charlie   == 10);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("--alpha 29 16 4.0 --charlie 10 6.25 -b");
        assert( alpha     == 29);
        assert( bravo     == 22);
        assert( got_bravo == Indicator.UsedEolDefault);
        assert( charlie   == 10);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("--alpha 29 16 4.0 --bravo 10 6.25 --charlie");
        assert( alpha     == 29);
        assert( bravo     == 10);
        assert( got_bravo == Indicator.Seen);
        assert( charlie   == 21);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    with (cp06) {
        Run("--alpha 29 16 4.0 --bravo 10 6.25 -c");
        assert( alpha     == 29);
        assert( bravo     == 10);
        assert( got_bravo == Indicator.Seen);
        assert( charlie   == 21);
        assert( delta     == 16);
        assert( echo      == 4.0);
        assert( got_echo  == Indicator.Seen);
        assert( foxtrot == 6.25);
        assert(!turn);
        assert(!twist);
        assert(!tumble);
    }

    class CP07: Fields00 {
        FArgBase arg_alpha, arg_bravo,   arg_charlie, arg_delta;
        FArgBase arg_echo,  arg_foxtrot;
        FArgBase arg_turn,  arg_twist,   arg_tumble;
        FArgBase arg_name,  arg_nino;

        this() {
            arg_alpha   = Named("alpha",   alpha,   0)  ('a');
            arg_bravo   = Named("bravo",   bravo,   0)  ('b');
            arg_charlie = Named("charlie", charlie, 0)  ('c');
            arg_delta   = Named("delta",   delta,   0)  ('d');
            arg_echo    = Named("echo",    echo,    0)  ('e');
            arg_foxtrot = Named("foxtrot", foxtrot, 0)  ('f');
            arg_turn    = Named("turn",    turn)        ('u');
            arg_twist   = Named("twist",   twist)       ('w');
            arg_tumble  = Named("tumble",  tumble)      ('m');
            arg_name    = Named("name",    name,    "") ('n');
            arg_nino    = Named("nino",    nino,    "") ('N');
        }
    }

    with (new CP07) {
        // This is a gross encapsulation violation.  Normally, the Handler
        // subclass would write something like this in its constructor:
        //
        // BetweenNAndMOf(2, 3,
        //      Named(...),
        //      Named(...),
        //      Named(...),
        //      Named(...));
        //
        // All those arg_xxx variables would normally be necessary only when an
        // argument was a member of two or more argument groups, and that's rare
        // in practice.

        BetweenNAndMOf(2, 3, arg_alpha, arg_bravo, arg_charlie, arg_delta);
        FailRun("--alpha 23",                                "Please specify between 2 and 3 of the --alpha option, the --bravo option, the --charlie option and the --delta option");
        Run    ("--alpha 1 --bravo 2");
        Run    ("--alpha 1 --bravo 2 --charlie 3");
        Run    ("--alpha 1 --bravo 2 --name Donald --nino quack-quack-quack");
        FailRun("--alpha 1 --bravo 2 --charlie 3 --delta 4", "Please specify between 2 and 3 of the --alpha option, the --bravo option, the --charlie option and the --delta option");
    }

    with (new CP07) {
        ExactlyNOf(2, arg_alpha, arg_bravo, arg_charlie, arg_delta);
        FailRun("--alpha 23",                                "Please specify exactly 2 of the --alpha option, the --bravo option, the --charlie option and the --delta option");
        Run    ("--alpha 1 --bravo 2");
        FailRun("--alpha 1 --bravo 2 --charlie 3",           "Please specify exactly 2 of the --alpha option, the --bravo option, the --charlie option and the --delta option");
        FailRun("--alpha 1 --bravo 2 --charlie 3 --delta 4", "Please specify exactly 2 of the --alpha option, the --bravo option, the --charlie option and the --delta option");
    }

    with (new CP07) {
        ExactlyOneOf(arg_alpha, arg_bravo);
        FailRun("",                                   "Please specify exactly 1 of the --alpha option and the --bravo option");
        Run    ("--alpha 1");
        Run    ("--bravo 33");
        Run    ("--bravo 33 --charlie 4 --delta 59");
        FailRun("--alpha 1 --bravo 2",                "Please specify exactly 1 of the --alpha option and the --bravo option");
    }

    with (new CP07) {
        AtMostNOf(2, arg_alpha, arg_bravo, arg_charlie);
        Run    ("");
        Run    ("--alpha 23");
        Run    ("--alpha 1 --bravo 2");
        Run    ("--alpha 1 --bravo 2 --delta 3");
        FailRun("--alpha 1 --bravo 2 --charlie 4 --name Clarence", "Please don't specify more than 2 of the --alpha option, the --bravo option and the --charlie option");
    }

    with (new CP07) {
        AtMostOneOf(arg_alpha, arg_bravo, arg_charlie);
        Run    ("");
        Run    ("--alpha 23");
        Run    ("--bravo 2");
        Run    ("--charlie 194 --delta 3");
        Run    ("--delta 3");
        Run    ("--charlie 8");
        FailRun("--alpha 1 --bravo 2",              "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
        FailRun("--alpha 1 --charlie 2",            "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
        FailRun("--charlie 1 --bravo 2",            "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
        FailRun("--alpha 22 --charlie 1 --bravo 2", "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
    }

    with (new CP07) {
        // Seenness shouldn't depend on whether the user chose to type long or
        // short names, but let's test it anyway:
        AtMostOneOf(arg_alpha, arg_bravo, arg_charlie);
        Run    ("");
        Run    ("-a23");
        Run    ("-b 2");
        Run    ("-c=194 -d 3");
        Run    ("-d=3");
        Run    ("-c8");
        FailRun("-a1 -b=2",        "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-a=1 -c 2",       "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-c1 -b2",         "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-a 22 -c 1 -b 2", "Please don't specify more than 1 of the --alpha option, the --bravo option and the --charlie option");
    }

    with (new CP07) {
        FirstOrNone(arg_alpha, arg_bravo, arg_charlie);
        Run    ("");
        Run    ("-a23");
        Run    ("-b2 -a22");
        Run    ("-c=194 -a3");
        Run    ("-d=3");
        FailRun("-b=2",      "Please don't specify the --bravo option without also specifying the --alpha option");
        FailRun("-c=2 -d=9", "Please don't specify the --charlie option without also specifying the --alpha option");
        FailRun("-c1 -b2",   "Please don't specify the --bravo option without also specifying the --alpha option");
    }

    with (new CP07) {
        AllOrNone(arg_alpha, arg_bravo, arg_charlie);
        Run    ("--alpha 6 --charl 4 --brav 5");
        Run    ("");
        FailRun("-a6 -b5",     "Please specify either all or none of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-a6 -c5",     "Please specify either all or none of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-c6 -b5",     "Please specify either all or none of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-c6 -b5 -d2", "Please specify either all or none of the --alpha option, the --bravo option and the --charlie option");
    }

    with (new CP07) {
        AllOrNone(arg_alpha, arg_bravo);
        Run    ("--alpha 6 --charl 4 --brav 5");
        Run    ("");
        FailRun("-a6 -c5",     "Please specify either both or neither of the --alpha option and the --bravo option");
        FailRun("-b6 -c5",     "Please specify either both or neither of the --alpha option and the --bravo option");
        FailRun("-c6 -b5",     "Please specify either both or neither of the --alpha option and the --bravo option");
        FailRun("-c6 -b5 -d2", "Please specify either both or neither of the --alpha option and the --bravo option");
    }

    with (new CP07) {
        // A single argument can belong to more than one arg group.
        // This models HNAS's `sd-write-block' command, which accepts either an
        // SD location as three parameters or a --last-read switch.
        AllOrNone   (arg_alpha, arg_bravo, arg_charlie);
        ExactlyOneOf(arg_alpha, arg_twist);

        Run("-a0 -b1 -c2");
        Run("--twist");
        FailRun("",               "Please specify exactly 1 of the --alpha option and the --twist option");
        FailRun("-a0 -b1",        "Please specify either all or none of the --alpha option, the --bravo option and the --charlie option");
        FailRun("-a0 -b2 -c2 -w", "Please specify exactly 1 of the --alpha option and the --twist option");
    }

    // Test EOL defaults:

    class CP08: Fields00 {
        this() {
            Named("alpha",   alpha,   1)  ('a').EqualsDefault(5);
            Named("bravo",   bravo,   2)  ('b').EqualsDefault(6);
            Named("charlie", charlie, 3)  ('c').EqualsDefault(7);
            Named("delta",   delta,   4)  ('d').EqualsDefault(8);
        }
    }

    with (new CP08) {
        auto eq_aargs = ["fake-program-name", "--alpha", "--bravo=12", "-cd=13"];
        Parse(eq_aargs);
        assert(alpha   ==  5);
        assert(bravo   == 12);
        assert(charlie ==  7);
        assert(delta   == 13);
    }

    // Test File arguments:

    class Fields01: TestableHandler {
        File alpha, bravo, charlie, delta, echo, foxtrot;
        string alpha_error, bravo_error, charlie_error, delta_error, echo_error, foxtrot_error;
        Indicator got_alpha, got_bravo, got_charlie, got_delta, got_echo, got_foxtrot;

        this() {
            Preserve;
        }

        enum Mode = "rb";

        void RunWithHardOpenFailure(in string joined_args) {
            try {
                Run(joined_args);
                assert(false, "The open-failure should have thrown an exception; it didn't");
            }
            catch (Exception) { }
        }

        void RunWithHardOpenFailure(string[] args) {
            try {
                Run(args);
                assert(false, "The open-failure should have thrown an exception; it didn't");
            }
            catch (Exception) { }
        }
    }

    class CP10: Fields01 {
        this(in string echo_default_name, in string foxtrot_default_name) {
            // Mandatory with hard failure:
            Named("alpha", alpha, Mode, null)                                    .EolDefault("-");

            // Mandatory with soft failure:
            Named("bravo", bravo, Mode, &bravo_error)                            .EolDefault("-");

            // Optional with indicator and hard failure:
            Named("charlie", charlie, Mode, got_charlie, null)                   .EolDefault("-");

            // Optional with indicator and soft failure:
            Named("delta", delta, Mode, got_delta, &delta_error)                 .EolDefault("-");

            // Optional with default filename and hard failure:
            Named("echo", echo, Mode, echo_default_name, null)                   .EolDefault("-");

            // Optional with default filename and soft failure:
            Named("foxtrot", foxtrot, Mode, foxtrot_default_name, &foxtrot_error).EolDefault("-");
        }
    }

    @trusted auto test_named_file_arguments() {
        // @trusted because it refers to __gshared stdin, but never from
        // multi-threaded code.

        auto cp10a = new CP10(existent_file, existent_file);
        cp10a.ExpectSummary("--alpha <alpha> --bravo <bravo> [--charlie <charlie>] [--delta <delta>] [--echo <echo>] [--foxtrot <foxtrot>]");
        cp10a.FailRun("", "This command needs the --alpha option to be specified");

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo", existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        cp10a.RunWithHardOpenFailure(["--alpha", nonexistent_file, "--bravo", existent_file]);

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo", nonexistent_file]);
            assert( alpha.isOpen);
            assert(!bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert(!bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        cp10a.RunWithHardOpenFailure(["--alpha", existent_file, "--bravo", nonexistent_file, "--charlie", nonexistent_file]);

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo", nonexistent_file, "--charlie", existent_file]);
            assert( alpha.isOpen);
            assert(!bravo.isOpen);
            assert( charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert(!bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.NotSeen);
        }

        cp10a.RunWithHardOpenFailure(["--alpha", existent_file, "--bravo", nonexistent_file, "--delta", nonexistent_file]);

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo", existent_file, "--delta", existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.Seen);
        }

        cp10a.RunWithHardOpenFailure(["--alpha", existent_file, "--bravo", existent_file, "--echo", nonexistent_file]);

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo", existent_file, "--foxtrot", existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo", existent_file, "--foxtrot", nonexistent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert(!foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert(!foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        auto cp10b = new CP10(nonexistent_file, nonexistent_file);
        cp10b.RunWithHardOpenFailure(["--alpha", existent_file, "--bravo", existent_file]);

        with (cp10b) {
            Run(["--alpha", existent_file, "--bravo", existent_file, "--echo", existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert(!foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert(!foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        with (cp10b) {
            Run(["--alpha", existent_file, "--bravo", existent_file, "--echo", existent_file, "--foxtrot", existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        with (cp10a) {
            Run(["--alpha", existent_file, "--bravo"]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
            assert( alpha       != stdin);
            assert( bravo       == stdin);
        }

        with (cp10a) {
            Run(["--bravo", existent_file, "--alpha"]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
            assert( alpha       == stdin);
            assert( bravo       != stdin);
        }

        with (cp10a) {
            Run(["--bravo", existent_file, "--alpha", existent_file, "--charlie"]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert( charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.UsedEolDefault);
            assert( got_delta   == Indicator.NotSeen);
            assert( charlie     == stdin);
        }

        with (cp10a) {
            Run(["--bravo", existent_file, "--alpha", existent_file, "--delta"]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.UsedEolDefault);
            assert( delta       == stdin);
        }
    }

    class CP11: Fields01 {
        this(in string echo_default_name, in string foxtrot_default_name) {
            // Mandatory with hard failure:
            Pos("alpha", alpha, Mode, null);

            // Mandatory with soft failure:
            Pos("bravo", bravo, Mode, &bravo_error);

            // Optional with indicator and hard failure:
            Pos("charlie", charlie, Mode, got_charlie, null);

            // Optional with indicator and soft failure:
            Pos("delta", delta, Mode, got_delta, &delta_error);

            // Optional with default filename and hard failure:
            Pos("echo", echo, Mode, echo_default_name, null);

            // Optional with default filename and soft failure:
            Pos("foxtrot", foxtrot, Mode, foxtrot_default_name, &foxtrot_error);
        }
    }

    @trusted auto test_positional_file_arguments() {
        // @trusted because it refers to __gshared stdin, but never from
        // multi-threaded code.

        auto cp11a = new CP11(existent_file, existent_file);
        cp11a.ExpectSummary("<alpha> <bravo> [<charlie>] [<delta>] [<echo>] [<foxtrot>]");
        cp11a.FailRun("", "This command needs the alpha to be specified");

        with (cp11a) {
            Run([existent_file, existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        cp11a.RunWithHardOpenFailure([nonexistent_file, existent_file]);

        with (cp11a) {
            Run([existent_file, nonexistent_file]);
            assert( alpha.isOpen);
            assert(!bravo.isOpen);
            assert(!charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert(!bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.NotSeen);
            assert( got_delta   == Indicator.NotSeen);
        }

        cp11a.RunWithHardOpenFailure([existent_file, nonexistent_file, nonexistent_file]);

        with (cp11a) {
            Run([existent_file, nonexistent_file, existent_file]);
            assert( alpha.isOpen);
            assert(!bravo.isOpen);
            assert( charlie.isOpen);
            assert(!delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert(!bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.NotSeen);
        }

        cp11a.RunWithHardOpenFailure([existent_file, nonexistent_file, "-", nonexistent_file]);

        with (cp11a) {
            // Also tests that a bare dash is interpreted as a literal string,
            // rather than the start of an option:
            Run([existent_file, existent_file, "-", existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert( charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( charlie == stdin);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.Seen);
        }

        cp11a.RunWithHardOpenFailure([existent_file, existent_file, "-", "-", nonexistent_file]);

        with (cp11a) {
            Run([existent_file, existent_file, existent_file, existent_file, existent_file, existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert( charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.Seen);
        }

        with (cp11a) {
            Run([existent_file, existent_file, existent_file, existent_file, existent_file, nonexistent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert( charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert(!foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert(!foxtrot_error.empty);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.Seen);
        }
    
        auto cp11b = new CP11(nonexistent_file, nonexistent_file);
        cp11b.RunWithHardOpenFailure([existent_file, existent_file]);

        with (cp11b) {
            Run([existent_file, existent_file, existent_file, existent_file, existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert( charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert(!foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert(!foxtrot_error.empty);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.Seen);
        }

        with (cp11b) {
            Run([existent_file, existent_file, existent_file, existent_file, existent_file, existent_file]);
            assert( alpha.isOpen);
            assert( bravo.isOpen);
            assert( charlie.isOpen);
            assert( delta.isOpen);
            assert( echo.isOpen);
            assert( foxtrot.isOpen);
            assert( bravo_error.empty);
            assert( delta_error.empty);
            assert( foxtrot_error.empty);
            assert( got_charlie == Indicator.Seen);
            assert( got_delta   == Indicator.Seen);
        }
    }

    static if (!existent_file.empty && !nonexistent_file.empty) {
        test_named_file_arguments;
        test_positional_file_arguments;
    }

    // Regex-based string verification

    class Fields02(Char, Str): TestableHandler {
        Str alpha, bravo;
        Captures!(Char[])[] alpha_caps, bravo_caps;

        this() {
            Preserve;
        }
    }

    class CP20(Char, Str): Fields02!(Char, Str) {
        this() {
            // With stored captures:
            Named("alpha", alpha, "".to!Str)    // Ethernet or aggregate port name: / ^ (?: eth | agg ) \d{1,3} $ /x
                .AddRegex(` ^ (?P<TYPE> eth | agg ) (?! \p{alphabetic} ) `.to!Str, "x", "The port name must begin with 'eth' or 'agg'").Snip
                .AddRegex(` ^ (?P<NUMBER> \d{1,3} ) (?! \d )             `.to!Str, "x", "The port type ('{0:TYPE}') must be followed by one, two or three digits").Snip
                .AddRegex(` ^ $                                          `.to!Str, "x", "The port name ('{0:TYPE}{1:NUMBER}') mustn't be followed by any other characters")
                .StoreCaptures(alpha_caps);

            // Without stored captures:
            Named("bravo", bravo, "".to!Str)    // A person's name: a capital letter, followed by some small letters
                .AddRegex(` ^ (?P<INITIAL> \p{uppercase} ) `.to!Str, "x", "The name must start with a capital letter").Snip
                .AddRegex(` ^ \p{lowercase}* $             `.to!Str, "x", "The initial, {0:INITIAL}, must be followed by nothing but small letters");
        }
    }

    auto test_regexen(Char, Str) () {
        with (new CP20!(Char, Str)) {
                Run("--alpha eth2");
                assert(alpha_caps[0]["TYPE"]           == "eth");
                assert(alpha_caps[1]["NUMBER"].to!uint == 2);
                assert(alpha                           == "eth2");

            Run("--alpha agg39");
            assert(alpha_caps[0]["TYPE"]           == "agg");
            assert(alpha_caps[1]["NUMBER"].to!uint == 39);
            assert(alpha                           == "agg39");

            // Because we stored captures, we expect interpolation in error messages:
            FailRun("--alpha ether",   "The port name must begin with 'eth' or 'agg'");
            FailRun("--alpha arc22",   "The port name must begin with 'eth' or 'agg'");
            FailRun("--alpha agg",     "The port type ('agg') must be followed by one, two or three digits");
            FailRun("--alpha eth221b", "The port name ('eth221') mustn't be followed by any other characters");

            Run("--bravo José");
            assert(bravo == "José");

            // We didn't store captures, and so we don't expect interpolation:
            FailRun("--bravo elliott",         "The name must start with a capital letter");
            FailRun("--bravo O'Hanrahanrahan", "The initial, {0:INITIAL}, must be followed by nothing but small letters");
        }
    }

    test_regexen!(char,  string)  ();
    test_regexen!(wchar, wstring) ();
    test_regexen!(dchar, dstring) ();

    // Prove that class Handler destroys its state if we don't call Preserve():
    @safe class Fields03: TestableHandler {
        int alpha;

        this() {
            Named("alpha", alpha, 0);
        }

        auto Test() {
            immutable command = "--alpha 43";
            Run(command);
            assert(alpha == 43);

            FailRun(command, "This command has no --alpha option");
        }
    }

    with (new Fields03)
        Test;
}

}   // @safe
