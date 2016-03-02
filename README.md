# Argon
A processor for command-line arguments, an alternative to Getopt, written in D

```d
#!/usr/bin/rdmd --shebang -unittest -g -debug -w

import argon;

import std.stdio;

// Imagine a program that creates widgets of some kind.

enum Colours {black, blue, green, cyan, red, magenta, yellow, white}

// Write a class that inherits from argon.Handler:

class MyHandler: argon.Handler {

    // Inside your class, define a set of data members.
    // Argon will copy user input into these variables.

    uint size;
    Colours colour;
    bool winged;
    uint nr_windows;
    string name;
    argon.Indicator got_name;

    // In your constructor, make a series of calls to Named(),
    // Pos() and (not shown here) Incremental().  These calls tell Argon
    // what kind of input to expect and where to deposit the input after
    // decoding and checking it.

    this() {
        // The first argument is positional (meaning that the user specifies
        // it just after the command name, with an --option-name), because we
        // called Pos().  It's mandatory, because the Pos() invocation doesn't
        // specify a default value or an indicator.  (Indicators are explained
        // below.)  The AddRange() call rejects user input that isn't between
        // 1 and 20, inclusive.
        Pos("size of the widget", size).AddRange(1, 20);

        // The second argument is also positional, but it's optional, because
        // we specified a default colour: by default, our program will create
        // a green widget.  The user specifies colours by their names ('black',
        // 'blue', etc.), or any unambiguous abbreviation.
        Pos("colour of the widget", colour, Colours.green);

        // The third argument is a Boolean option that is named, as all
        // Boolean arguments are.  That means a user who wants to override
        // the default has to specify it by typing "--winged", or some
        // unambiguous abbreviation of it.  We've also provided a -w shortcut.
        //
        // All Boolean arguments are optional.
        Named("winged", winged) ('w');

        // The fourth argument, the number of windows, is a named argument,
        // with a long name of --windows and a short name of -i, and it's
        // optional.  A user who doesn't specify a window count gets six
        // windows.  Our AddRange() call ensures that no widget has more
        // than twelve and, because we pass in a uint, Argon will reject
        // all negative numbers.  The string "number of windows" is called a
        // description, and helps Argon auto-generate a more helpful
        // syntax summary.
        Named("windows", nr_windows, 6) ('i') ("number of windows").AddRange(0, 12);

        // The user can specify a name for the new widget.  Since the user
        // could explicitly specify an empty name, our program uses an
        // indicator, got_name, to determine whether a name was specified or
        // not, rather than checking whether the name is empty.
        Named("name", name, got_name) ('n').LimitLength(0, 20);
    }

    // Now write a separate method that calls Parse() and does something with
    // the user's input.  If the input is valid, your class's data members will
    // be populated; otherwise, Argon will throw an exception.
    
    auto Run(string[] args) {
        try {
            Parse(args);
            writeln("Size:    ", size);
            writeln("Colour:  ", colour);
            writeln("Wings?   ", winged);
            writeln("Windows: ", nr_windows);
            if (got_name)
                writeln("Name:    ", name);

            return 0;
        }
        catch (argon.ParseException x) {
            stderr.writeln(x.msg);
            stderr.writeln(BuildSyntaxSummary);
            return 1;
        }
    }
}

int main(string[] args) {
    auto handler = new MyHandler;
    return handler.Run(args);
}
```

There's plenty more that Argon can do.

Features for you:
* You can mix mandatory and optional arguments
* You can freely mix named arguments (specified with `--option` syntax) and positional arguments (defined by their position on the command line)
* Argon has first-class support for positional arguments: they're validated, range-checked and deposited into type-safe variables; you don't end up picking them out of `argv` and converting them manually after named arguments have been removed
* Argon can either pass through unused arguments (as long as they don't look like `--option`s) or fail the parse, whichever you prefer, although its first-class support for positional arguments makes the need for pass-through rare
* Optional arguments have caller-defined default values
* Argon can open files specified at the command line, with an open mode and error-handling protocol that you choose and a convention that `"-"` stands for either `stdin` or `stdout`, depending on the open mode
* An argument can have a different default value if an option is specified at the end of a command line, so that `list-it --as-text` can be short for `list-it --as-text -`, which opens `stdout`, whereas `list-it --as-text output.txt` creates `output.txt`
* You can tell unambiguously whether a user specified an argument, without having to pick a default value and hope the user doesn't guess it
* You can specify range-checks for numerical arguments and length limits for string arguments
* Argon supports non-Ascii long and short option names and enum names
* Argon auto-generates syntax summaries (help text), with support for optional argument descriptions and undocumented arguments; letting Argon generate syntax summaries makes it more likely that they'll stay current under maintenance
* Argument groups enable flexible specification of which combinations of arguments are allowed together, so that you don't have to write error-checking code yourself
* You can choose decimal, hex, octal or even binary as the default radix for individual numeric arguments -- though the user can always override your default
* String arguments can be validated by regular expressions with associated user-friendly error messages; these regexes can capture segments of the user's input, so that it's ready to use after a successful parse
* Incremental arguments increment a counter by 1 each time they're used, as in `--verbose --verbose --verbose` or `-vvv`
* An argument can have any number of names, so you can please everyone by supporting both `--colour` and `--color`
* Argon gently encourages you to move your command-line processing into a class of its own for better modularity and lifetime-management, although you *can* use it without deriving a class if you wish

Features for your users:
* The ability to abbreviate option names
* Flexible syntax: a user can say `-t5`, `-t=5` or `-t 5`
* Bundling of short names, enabled by default, so that `-a -b -c 5` can be written as `-abc5`
* The `--` options terminator, which forces all subsequent tokens to be interpreted as positional arguments
* The ability to abbreviate option names and `enum` values
* The ability to specify numeric arguments in binary, octal or hex as an alternative to decimal
* Better error messages than it would be worth writing for most programs))

Some of this functionality is available in `std.getopt`; some isn't.  Stick with `getopt` if you need the following features, which are not currently implemented in Argon:

* Array arguments
* Hash arguments
* Callback options
* Case-insensitivity: a mix of Unix-style dashes and double dashes with DOS-style case-insensitivity
* The ability to ignore and pass back unused arguments that look like `--option`s: only tokens resembling positional arguments can be passed back

Future directions:

* Make Handler.BuildSyntaxSummary() reflect the first-or-none behaviour of consecutive positional, optional args, as well as first-or-none and all-or-none argument groups.
* An optional, positional File argument already supports a simplified version of what `cat`(1) does and what many Perl programs do: read from a file specified at the command line, or stdin otherwise.  It would be good to generalise this functionality to be able to read from any number of input files, as Perl's diamond operator does.

Argon parses Unix-style syntax, as in `ls -lah --author foo*`.  If you wanted to support other syntaxes, such as MS-DOS-style `dir foo.* /s /b`, replacing struct Parser and a few parts of class Handler, along with all the unit tests that follow them, should get you most of the way.  The rest of the code ought to be reusable in more or less its current form.  The author has no plans to support MS-DOS-style syntax.
