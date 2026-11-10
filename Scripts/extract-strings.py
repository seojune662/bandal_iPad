#!/usr/bin/env python3
"""Extract the Korean SwiftUI literals that are LocalizedStringKeys and keep
App/Resources/Localization/en.lproj/Localizable.strings in sync with them.

    python3 Scripts/extract-strings.py                  # report, then rewrite the extracted section
    python3 Scripts/extract-strings.py --stringsdata D  # also check every key against the compiler
    python3 Scripts/extract-strings.py --unreachable F  # also list every unreachable Korean literal (TSV)
    python3 Scripts/extract-strings.py --prune          # delete translations whose key is gone
    python3 Scripts/extract-strings.py --selftest       # the lexer, key and table checks

The .strings file is the translation store; the script never writes English. It
keeps every translation, sorts the section, prints the keys still to translate (ready
to paste) and exits 1 until none are missing or stale. Text above the section header
is someone else's: copied through byte for byte, and a key defined there is not
repeated below. Comments below the header are not kept. Needs macOS (plutil).

A literal without interpolation is its own key and its translation is shown as is.
With interpolation the key is a format string: % in the text becomes %%, and \\(…) is
    Int, Int64 %lld · Int8/16/32 %d · UInt, UInt64 %llu · UInt8/16/32 %u · Float %f
    Double, CGFloat %lf · \\(x, specifier: "%.1f") that specifier · anything else %@
(`formatSpecifier`, SwiftUICore.swiftinterface). A translation may reorder them: %2$lld … %1$@.

There is no type checker here. An interpolation is typed only when its shape decides
it (`simple`: .count, `as? Int ?? 0`, String(…), string literals, .formatted(), an
explicit specifier); any other one matches whichever specifier a key of the same text
has in the table. A new one of those needs the compiler once:
    xcodebuild … SWIFT_EMIT_LOC_STRINGS=YES build
    --stringsdata <derivedData>/Build/Intermediates.noindex/Bandal.build/<config>-iphonesimulator/Bandal.build/Objects-normal/<arch>
That run is the real check, for the position table too: a LocalizedStringKey position
the table lacks shows up as MISSED, an app function of the same name as EXTRA.

Glossary (the product's own English wins: App Store text, DesktopNative/settings-en.json):
  반달 Bandal · 플러스 Plus · 프로 Pro · 과목 course · 자료 material · 자료실 Library
  노트 note · 학교 university · 학업 보드 Study Board · 암기테이프 memorization tape
  필기 handwriting (strokes: ink; text for a page: notes) · 주석 annotation · 메모 note
  학습 study · 학습 공간 study space · 글 article · 표현 phrase · 복습 review · 원문 source text
  녹음 recording · 자막 captions · 전사 transcript · 영역 pane or (AI selection) area
  동기화 sync · 저장소 storage · 구독 subscription · 사용량 usage · 충전 credit
"""
import argparse
import bisect
import collections
import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCES = "App"
STRINGS = "App/Resources/Localization/en.lproj/Localizable.strings"
HEADER = "/* ===== App strings (extracted) ===== */"
HANGUL = re.compile(r"[\u1100-\u11FF\u3130-\u318F\uA960-\uA97F\uAC00-\uD7FF]")

# Where a string literal is typed LocalizedStringKey: callee -> argument slots (a
# positional index or a label). Each has a @_disfavoredOverload StringProtocol twin,
# so a literal picks the key and a String variable does not.
# ponytail: a closed list of what this code base uses today. NavigationLink, .help,
# LocalizedStringKey("…"), the app's own LocalizedStringKey parameters … are not found
# (--stringsdata reports them as MISSED): add rows once Strings get converted.
LSK_POSITIONS = {
    # named in the task
    "Text": {0}, "Button": {0}, "Label": {0}, "Toggle": {0}, "TextField": {0},
    "Picker": {0}, "Section": {0}, "navigationTitle": {0}, "Menu": {0},
    "LabeledContent": {0}, "Link": {0}, "ProgressView": {0},
    # the others this code base passes literals to (per the compiler's extraction)
    "DisclosureGroup": {0}, "ContentUnavailableView": {0}, "Stepper": {0}, "DatePicker": {0},
    "alert": {0}, "confirmationDialog": {0},
    "accessibilityLabel": {0}, "accessibilityValue": {0}, "accessibilityHint": {0},
    "accessibilityAction": {"named"},
}

NUMERIC = {
    "Int": "%lld", "Int64": "%lld", "Int8": "%d", "Int16": "%d", "Int32": "%d",
    "UInt": "%llu", "UInt64": "%llu", "UInt8": "%u", "UInt16": "%u", "UInt32": "%u",
    "Float": "%f", "Double": "%lf", "CGFloat": "%lf",
}
CONVERSIONS = dict(NUMERIC, String="%@")
UNTYPED = "(?:%s)" % "|".join(sorted(set(map(re.escape, CONVERSIONS.values())), key=len, reverse=True))
SPECIFIER = re.compile(r"%%|%(?:(\d+)\$)?[-+ #0]*\d*(?:\.\d+)?((?:hh|h|ll|l|q|L|z|t|j)?[@a-zA-Z])")

# ---------------------------------------------------------------- Swift lexer

STRING_OPEN = re.compile(r'(#*)("""|")')
REGEX_OPEN = re.compile(r"(#+)/")
IDENT = re.compile(r"[^\W\d]\w*|\$\w+|`[^`\n]+`")
NUMBER = re.compile(r"\d\w*(?:\.\d\w*)?")
OPCHARS = set("/=-+!*%<>&|^~?")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}


class Lit(collections.namedtuple("Lit", "parts")):
    """A string literal; parts are str (cooked text) or Interp."""

    def text(self):
        return "".join(p for p in self.parts if isinstance(p, str))

    def source(self):
        return "".join(p if isinstance(p, str) else "\\(%s)" % p.source for p in self.parts)


Interp = collections.namedtuple("Interp", "source tokens")  # one \(…) of a literal


def skip_opaque(src, i):
    """The offset after the comment or #/…/# regex literal that starts at `i`, else `i`.
    ponytail: a bare /…/ regex literal (Swift 6 mode) is not recognised; a quote inside
    one would open a string. Skip those here too if the project turns that mode on."""
    if src.startswith("//", i):
        end = src.find("\n", i)
        return len(src) if end < 0 else end
    regex = REGEX_OPEN.match(src, i)
    if regex:
        end = src.find("/" + regex.group(1), regex.end())
        if end < 0:
            raise SyntaxError("unterminated regex literal at offset %d" % i)
        return end + 1 + len(regex.group(1))
    if not src.startswith("/*", i):
        return i
    level, i = 1, i + 2
    while i < len(src) and level:  # block comments nest
        if src.startswith("/*", i):
            level, i = level + 1, i + 2
        elif src.startswith("*/", i):
            level, i = level - 1, i + 2
        else:
            i += 1
    return i


def lex(src, i=0, until_paren=False):
    """Tokens of Swift source as (kind, value, offset, space_before); kinds are id,
    num, str (value is a Lit) and op. With until_paren, stops after the ')' that
    closes an interpolation and returns (tokens, next_offset)."""
    tokens, depth, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c.isspace():
            i += 1
            continue
        after = skip_opaque(src, i)
        if after != i:
            i = after
            continue
        start, spaced = i, i == 0 or src[i - 1].isspace()
        m = STRING_OPEN.match(src, i)
        if m:
            lit, i = read_string(src, m)
            tokens.append(("str", lit, start, spaced))
            continue
        m = IDENT.match(src, i) or (c == "#" and IDENT.match(src, i + 1))
        if m:
            i = m.end()
            tokens.append(("id", src[start:i].strip("`"), start, spaced))
            continue
        m = NUMBER.match(src, i)
        if m:
            i = m.end()
            tokens.append(("num", m.group(), start, spaced))
            continue
        if c in OPCHARS or src.startswith("..", i):
            i += 1
            while i < n and (src[i] in OPCHARS or src[i] == ".") and not src.startswith(("//", "/*"), i):
                i += 1
            tokens.append(("op", src[start:i], start, spaced))
            continue
        i += 1
        if until_paren and c in "()":
            depth += 1 if c == "(" else -1
            if depth < 0:
                return tokens, i
        tokens.append(("op", c, start, spaced))
    if until_paren:
        raise SyntaxError("unterminated interpolation")
    return tokens


def read_string(src, m):
    """Reads the literal whose opening delimiter matched `m`; returns (Lit, next_offset)."""
    hashes, quote = m.groups()
    multiline, escape, close = quote == '"""', "\\" + hashes, quote + hashes
    i, items = m.end(), []  # items: a source char, ("esc", text), ("cont",) or an Interp
    while not src.startswith(close, i):
        if i >= len(src) or (src[i] == "\n" and not multiline):
            raise SyntaxError("unterminated string literal at offset %d" % m.start())
        if not src.startswith(escape, i):
            items.append(src[i])
            i += 1
            continue
        i += len(escape)
        c = src[i]
        if c == "(":
            tokens, end = lex(src, i + 1, until_paren=True)
            items.append(Interp(src[i + 1:end - 1], tokens))
            i = end
        elif c == "u" and src[i + 1] == "{":
            end = src.index("}", i)
            items.append(("esc", chr(int(src[i + 2:end], 16))))
            i = end + 1
        elif c in ESCAPES:
            items.append(("esc", ESCAPES[c]))
            i += 1
        elif multiline and re.match(r"[ \t]*\n", src[i:]):
            i = src.index("\n", i)  # backslash-newline joins two lines; the newline still ends the source line
            items.append(("cont",))
        else:
            raise SyntaxError("unknown escape \\%s at offset %d" % (c, i))
    if multiline:
        items = unindent(items)
    parts = []
    for item in items:
        if isinstance(item, Interp):
            parts.append(item)
            continue
        text = item if isinstance(item, str) else item[1] if item[0] == "esc" else ""
        if parts and isinstance(parts[-1], str):
            parts[-1] += text
        else:
            parts.append(text)
    return Lit([p for p in parts if p != ""]), i + len(close)


def unindent(items):
    """Multi-line literal rules: drop the line after the opening quotes and the one
    holding the closing quotes, and strip that last line's indentation from the rest."""
    lines = [[]]
    for item in items:
        if item == "\n":
            lines.append([])
        else:
            lines[-1].append(item)
    indent, body, out = len(lines[-1]), lines[1:-1], []
    for number, line in enumerate(body):
        out.extend(line[indent:] if all(isinstance(c, str) and c.isspace() for c in line[:indent]) else line)
        if number < len(body) - 1 and out[-1:] != [("cont",)]:
            out.append("\n")
    return out


# ------------------------------------------------------------ expression tree

class Group:
    """A bracketed run of tokens; args are its comma-separated items (tokens and Groups)."""
    __slots__ = ("open", "callee", "args")

    def __init__(self, open_, callee=None):
        self.open, self.callee, self.args = open_, callee, [[]]


def tree(tokens, open_=""):
    root = Group(open_)
    stack = [root]
    for index, token in enumerate(tokens):
        kind, value = token[0], token[1]
        top = stack[-1]
        if kind == "op" and value in ("(", "[", "{"):
            called = value == "(" and index and tokens[index - 1][0] == "id" and not token[3]
            group = Group(value, tokens[index - 1][1] if called else None)
            top.args[-1].append(group)
            stack.append(group)
        elif kind == "op" and value in (")", "]", "}"):
            if len(stack) > 1:
                stack.pop()
        elif kind == "op" and value == "," and top.open in ("(", "["):
            top.args.append([])
        else:
            top.args[-1].append(token)
    return root


def is_tok(item, kind, value=None):
    return isinstance(item, tuple) and item[0] == kind and (value is None or item[1] == value)


def is_group(item, open_):
    return isinstance(item, Group) and item.open == open_


def split(expr, operator):
    """`expr` cut at each top-level binary `operator`."""
    parts = [[]]
    for item in expr:
        if is_tok(item, "op", operator) and parts[-1]:
            parts.append([])
        else:
            parts[-1].append(item)
    return parts


def ternary(expr):
    """(then, else) of `c ? a : b`. The `?` of a ternary has a space before it,
    the ones of optional chaining, `as?` and `Int?` do not."""
    def mark(item):
        return is_tok(item, "op", "?") and item[3]
    for i, item in enumerate(expr):
        if mark(item):
            depth = 0
            for j in range(i + 1, len(expr)):
                if mark(expr[j]):
                    depth += 1
                elif is_tok(expr[j], "op", ":"):
                    if depth == 0:
                        return expr[i + 1:j], expr[j + 1:]
                    depth -= 1
            return None
    return None


def parenthesized(expr):
    """The inside of `(expr)`, or None."""
    if len(expr) == 1 and is_group(expr[0], "(") and expr[0].callee is None and len(expr[0].args) == 1:
        return expr[0].args[0]
    return None


def results(expr):
    """The expressions `expr` can evaluate to, looking through `c ? a : b`, `a ?? b`,
    parentheses, a subscripted collection literal and `.map { … }`. The compiler types
    a literal as LocalizedStringKey through all of these, as long as every result is one."""
    branches = ternary(expr)
    if branches:
        return results(branches[0]) + results(branches[1])
    operands = split(expr, "??")
    if len(operands) > 1:
        return [r for operand in operands for r in results(operand)]
    inside = parenthesized(expr)
    if inside is not None:
        return results(inside)
    if len(expr) == 2 and is_group(expr[0], "[") and is_group(expr[1], "["):
        values = []
        for element in filter(None, expr[0].args):  # `key: value` or an array element; none after a trailing comma
            colon = next((i for i, item in enumerate(element) if is_tok(item, "op", ":")), -1)
            values += results(element if ternary(element) else element[colon + 1:])  # a ternary has its own colon
        return values
    if len(expr) > 2 and is_group(expr[-1], "{") and is_tok(expr[-2], "id") and expr[-2][1] in ("map", "flatMap"):
        body = expr[-1].args[0]
        named = next((i for i, item in enumerate(body) if is_tok(item, "id", "in")), -1)
        return results(body[named + 1:])
    return [expr]


def labelled(position, arg):
    """(slot, expression) of one call argument."""
    if len(arg) > 1 and is_tok(arg[0], "id") and is_tok(arg[1], "op", ":"):
        return arg[0][1], arg[2:]
    return position, arg


# ------------------------------------------------------- literals in context

Found = collections.namedtuple("Found", "token context")


def visit(group, out, keys, nested=False):
    """Appends a Found for every string literal under `group` and adds to `keys` the
    id() of each literal token that is typed LocalizedStringKey."""
    for position, arg in enumerate(group.args):
        slot, expr = labelled(position, arg)
        if group.open == "(" and slot in LSK_POSITIONS.get(group.callee, ()):
            values = results(expr)
            if all(len(v) == 1 and is_tok(v[0], "str") for v in values):
                keys.update(id(v[0]) for v in values)
        for at, item in enumerate(arg):
            if isinstance(item, Group):
                visit(item, out, keys, nested)
            elif item[0] == "str":
                out.append(Found(item, context(group, slot, arg, at, nested)))
                for part in item[1].parts:
                    if isinstance(part, Interp):
                        visit(tree(part.tokens), out, keys, nested=True)


def context(group, slot, arg, at, nested):
    """Where a literal sits, for the report on unreachable strings."""
    if group.open == "(" and group.callee:
        return "%s(%s)" % (group.callee, slot if isinstance(slot, int) else slot + ":")
    if nested:
        return "inside \\(…) of another literal"
    before = arg[at - 1] if at else None
    if isinstance(before, tuple) and before[0] in ("id", "op"):
        return "after `%s`" % before[1]
    return {"(": "in (…)", "[": "in […]", "{": "in {…}", "": "top level"}[group.open]


# ------------------------------------------------- typing an interpolation

INT_LITERAL, FLOAT_LITERAL = "int literal", "float literal"


def specifier(interp):
    """The format specifier of one \\(…), or None when its type is not evident."""
    args = tree(interp.tokens, "(").args
    labels = dict(labelled(i, arg) for i, arg in enumerate(args))
    if "specifier" in labels:
        value = labels["specifier"]
        plain = len(value) == 1 and is_tok(value[0], "str") and all(isinstance(p, str) for p in value[0][1].parts)
        return value[0][1].text() if plain else None
    if len(args) != 1 or 0 not in labels:
        return "%@"  # format:, formatter:, style:, timerInterval:, accessibilityName:
    return merge([type_of(args[0])])


def merge(types):
    """One specifier for alternatives or operands that share a type; a number literal
    takes the type of the others and is Int or Double on its own."""
    typed = {t for t in types if t not in (INT_LITERAL, FLOAT_LITERAL)}
    if None in typed or len(typed) > 1:
        return None
    if typed:
        return typed.pop()
    return "%lf" if FLOAT_LITERAL in types else "%lld"


def type_of(expr):
    branches = ternary(expr)
    if branches:
        return merge([type_of(branches[0]), type_of(branches[1])])
    operands = split(expr, "??")
    if len(operands) > 1:  # `??` unwraps its left side
        return merge([simple(o)[0] for o in operands[:-1]] + [type_of(operands[-1])])
    kind, optional = simple(expr)
    return "%@" if optional else kind  # Optional<T> has no specifier of its own


def simple(expr):
    """(type, is evidently Optional) of an expression without ?: or ??."""
    optional = any(is_tok(i, "op") and i[1][0] == "?" and not i[3] for i in expr)
    expr = [i for i in expr if not is_tok(i, "op", "!")]
    for operator in "+-*/%":
        operands = split(expr, operator)
        if len(operands) > 1:
            return merge([simple(o)[0] for o in operands]), False
    inside = parenthesized(expr)
    if inside is not None:
        return type_of(inside), optional
    cast = next((i for i in range(len(expr) - 1, -1, -1) if is_tok(expr[i], "id", "as")), -1)
    if cast >= 0:  # only a type known by name tells: `as TimeInterval` is a Double behind an alias
        target = [i for i in expr[cast + 1:] if not is_tok(i, "op")]
        return (CONVERSIONS.get(target[0][1]) if len(target) == 1 and is_tok(target[0], "id") else None), optional
    if len(expr) == 1 and is_tok(expr[0], "str"):
        return "%@", False
    if len(expr) == 1 and is_tok(expr[0], "num"):
        return (INT_LITERAL if re.fullmatch(r"[\d_]+|0[xob]\w+", expr[0][1]) else FLOAT_LITERAL), False
    if len(expr) == 2 and is_tok(expr[0], "id", "String") and is_group(expr[1], "("):
        return "%@", False  # Int(…) is left untyped: Int(a) converts, Int("12") and Int(exactly: a) are Optional
    if len(expr) > 2 and is_tok(expr[-1], "id", "count") and is_tok(expr[-2], "op") and expr[-2][1].endswith("."):
        return "%lld", optional
    if len(expr) > 3 and is_group(expr[-1], "(") and is_tok(expr[-2], "id", "formatted") and is_tok(expr[-3], "op"):
        return "%@", optional
    return None, optional


# ------------------------------------------------------------------ keys

class Key:
    """The .strings key of one literal."""

    def __init__(self, lit):
        self.format = any(isinstance(p, Interp) for p in lit.parts)
        if self.format:  # str segments are text, 1-tuples hold an interpolation's specifier (None: untyped)
            self.segments = [p.replace("%", "%%") if isinstance(p, str) else (specifier(p),) for p in lit.parts]
        else:
            self.segments = list(lit.parts)
        self.exact = (None,) not in self.segments

    def text(self):
        """The key, with %@ standing in for an untyped interpolation."""
        return "".join(s if isinstance(s, str) else s[0] or "%@" for s in self.segments)

    def matches(self, key):
        if self.exact:
            return key == self.text()
        pattern = "".join(re.escape(s) if isinstance(s, str) else re.escape(s[0]) if s[0] else UNTYPED for s in self.segments)
        return re.fullmatch(pattern, key, re.S) is not None


class Source:
    def __init__(self, path, text=None):
        self.path = path
        if text is None:
            with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
                text = handle.read()
        self.text = text
        self.starts = [0] + [m.end() for m in re.finditer("\n", text)]
        self.found, self.keys = [], set()
        visit(tree(lex(text)), self.found, self.keys)

    def line_col(self, offset):
        """1-based line and UTF-8 byte column, the way the compiler reports them."""
        line = bisect.bisect_right(self.starts, offset) - 1
        return line + 1, len(self.text[self.starts[line]:offset].encode("utf-8")) + 1

    def where(self, found):
        return "%s:%d" % (self.path, self.line_col(found.token[2])[0])


# ------------------------------------------------------------ .strings file

def quote(text):
    for raw, escaped in (("\\", "\\\\"), ('"', '\\"'), ("\n", "\\n"), ("\t", "\\t"), ("\r", "\\r")):
        text = text.replace(raw, escaped)
    return '"%s"' % text


def parse_strings(text, part="file"):
    """{key: value} of a .strings fragment, read by the system's own parser, so escapes,
    comments and duplicate keys (the last one wins) mean what they mean at run time."""
    if not text.strip(chr(0xFEFF) + " \t\r\n"):  # nothing but white space or a byte-order mark
        return {}
    done = subprocess.run(["plutil", "-convert", "binary1", "-o", "-", "-"], input=text.encode("utf-8"), capture_output=True)
    if done.returncode:
        sys.exit("%s does not parse (%s); nothing was changed.\n%s"
                 % (STRINGS, part, (done.stdout + done.stderr).decode("utf-8", "replace").strip()))
    return plistlib.loads(done.stdout)


def read_table():
    """(text above the header, keys defined there, translations below the header).
    Read as bytes, so the text above survives untouched, line endings included."""
    path = os.path.join(ROOT, STRINGS)
    data = b""
    if os.path.exists(path):
        with open(path, "rb") as handle:
            data = handle.read()
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        sys.exit("%s is not UTF-8; convert it first. Nothing was changed." % STRINGS)
    headers = list(re.finditer(r"^%s[ \t\r]*$" % re.escape(HEADER), text, re.M))  # only a line of its own counts
    if len(headers) > 1:
        sys.exit("%s has the section header %d times; join the sections by hand. Nothing was changed." % (STRINGS, len(headers)))
    if headers:
        above, below = text[:headers[0].start()], text[headers[0].end():]
    else:  # first run next to someone else's entries: separate the two sections, once
        above, below = (text.rstrip("\r\n") + "\n\n" if text.strip() else ""), ""
    return above, parse_strings(above, "above the header"), parse_strings(below, "below the header")


def write_table(text):
    """Replaces the file in one step and only with text plutil accepts. Returns a problem or None."""
    path, data = os.path.join(ROOT, STRINGS), text.encode("utf-8")  # an encoding error surfaces before the file is touched
    lint = subprocess.run(["plutil", "-lint", "-"], input=data, capture_output=True)
    if lint.returncode:
        return "plutil rejects the result, nothing was changed: " + (lint.stdout + lint.stderr).decode("utf-8", "replace").strip()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        with open(path + ".tmp", "wb") as handle:
            handle.write(data)
        os.replace(path + ".tmp", path)
    finally:
        if os.path.exists(path + ".tmp"):
            os.remove(path + ".tmp")
    return None


def conversions(text):
    """[(position or None, conversion)] of the format specifiers in `text`; %lf is %f."""
    found = []
    for m in SPECIFIER.finditer(text):
        if m.group() != "%%":
            found.append((int(m.group(1)) if m.group(1) else None, m.group(2).replace("lf", "f")))
    return found


def translation_error(key, value, is_format):
    """Why `value` cannot stand in for `key`, or None. A translation with the wrong
    argument type crashes in String(format:), so this is checked on every run."""
    if not value.strip():
        return "empty translation"
    if not is_format:
        return "%% in a plain string is shown as two percent signs" if "%%" in value else None
    wanted, given = [c for _, c in conversions(key)], conversions(value)
    if "%" in SPECIFIER.sub("", value):
        return "a literal percent sign must be written %%"
    if all(position is None for position, _ in given):
        return None if [c for _, c in given] == wanted else "specifiers must be %s in this order (or use %%1$…)" % wanted
    for position, conversion in given:
        if position is None or not 1 <= position <= len(wanted) or wanted[position - 1] != conversion:
            return "specifier %s does not match argument %s of %s" % (conversion, position, wanted)
    return None


# -------------------------------------------------------------- the compiler

def compiler_keys(sources, directory):
    """{path: [(line, column, key)]} from the .stringsdata files of a build made with
    SWIFT_EMIT_LOC_STRINGS=YES."""
    by_path = {os.path.realpath(os.path.join(ROOT, s.path)): s.path for s in sources}
    theirs, files = collections.defaultdict(list), glob.glob(os.path.join(directory, "*.stringsdata"))
    if not files:
        sys.exit("no .stringsdata files in %s" % directory)
    for path in files:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
        relative = by_path.get(os.path.realpath(data.get("source", "")))
        for entries in data.get("tables", {}).values() if relative else ():
            for entry in entries:
                where = entry["location"]
                theirs[relative].append((where["startingLine"], where["startingColumn"], entry["key"]))
    return theirs


def compare_with_compiler(sources, theirs):
    """Checks every literal the compiler extracted (in any language) against the
    script. Returns ({id(token): compiler key}, [problem lines])."""
    resolved, problems = {}, []
    for source in sources:
        mine = {source.line_col(f.token[2]): f for f in source.found}
        lost = []
        for line, col, key in theirs.get(source.path, []):
            # a multi-line literal is reported on the line after its opening quotes
            found = mine.get((line, col)) or mine.get((line - 1, col))
            if found is None:
                lost.append((line, col, key))
            elif id(found.token) not in source.keys:
                problems.append("MISSED %s:%d:%d %s  [%s]" % (source.path, line, col, quote(key), found.context))
            elif not Key(found.token[1]).matches(key):
                problems.append("WRONG  %s:%d:%d compiler %s, script %s" % (source.path, line, col, quote(key), quote(Key(found.token[1]).text())))
            else:
                resolved[id(found.token)] = key
        for line, col, key in lost:
            # the default of `a ?? "x"` is listed a second time at the start of the expression
            if not any(l == line and k == key for l, c, k in theirs[source.path] if c != col):
                problems.append("MISSED %s:%d:%d %s  [no literal there]" % (source.path, line, col, quote(key)))
        for found in source.found:
            if id(found.token) in source.keys and id(found.token) not in resolved:
                problems.append("EXTRA  %s %s  [%s]" % (source.where(found), quote(Key(found.token[1]).text()), found.context))
    return resolved, problems


# ---------------------------------------------------------------------- main

Scan = collections.namedtuple("Scan", "used unresolved unreachable shaped untyped")


def scan(sources, known, resolved):
    """Sorts every Korean literal into keys and plain Strings. `used` maps a key to
    [(where, is a format)]; `unresolved` lists new literals whose key cannot be told
    without the compiler; `unreachable` holds (Source, Found) of the Strings."""
    used, unresolved, unreachable, shaped, untyped = collections.defaultdict(list), [], [], 0, 0
    formats = [k for k in known if "%" in k]
    for source in sources:
        for found in source.found:
            lit = found.token[1]
            if not HANGUL.search(lit.text()):
                continue
            if id(found.token) not in source.keys:
                unreachable.append((source, found))
                continue
            key = Key(lit)
            shaped += sum(1 for s in key.segments if isinstance(s, tuple) and s[0])
            untyped += key.segments.count((None,))
            if key.exact:
                names = [key.text()]
            elif id(found.token) in resolved:
                names = [resolved[id(found.token)]]
            else:
                names = [k for k in formats if key.matches(k)]
            if not names:
                unresolved.append((source.where(found), lit.source()))
            for name in names:
                used[name].append((source.where(found), key.format))
    return Scan(used, unresolved, unreachable, shaped, untyped)


def top(counter, limit):
    return "\n".join("    %5d  %s" % (count, name) for name, count in counter.most_common(limit))


def report(sources, found, typed_by, listing):
    reachable = sum(len(v) for v in found.used.values()) + len(found.unresolved)
    print("Scanned %d Swift files under %s/: %d string literals, %d with Korean text."
          % (len(sources), SOURCES, sum(len(s.found) for s in sources), reachable + len(found.unreachable)))
    print("\nLocalizedStringKey positions: %d literals -> %d unique keys" % (reachable, len(found.used) + len(found.unresolved)))
    print("  interpolations typed by shape: %d; typed by the %s: %d" % (found.shaped, typed_by, found.untyped))
    texts = {f.token[1].source() for _, f in found.unreachable}
    print("\nNot reachable (the literal is a String): %d literals, %d unique texts" % (len(found.unreachable), len(texts)))
    print("  by directory:\n" + top(collections.Counter(os.path.dirname(s.path) for s, _ in found.unreachable), 12))
    print("  top files:\n" + top(collections.Counter(s.path for s, _ in found.unreachable), 25))
    print("  top contexts (callee and argument slot, or the token before the literal):\n"
          + top(collections.Counter(f.context for _, f in found.unreachable), 30))
    if listing:
        with open(listing, "w", encoding="utf-8") as handle:
            handle.write("file\tline\tcontext\tliteral\n")
            for source, item in found.unreachable:
                path, line = source.where(item).rsplit(":", 1)
                literal = item.token[1].source().replace("\n", "\\n").replace("\t", " ")
                handle.write("%s\t%s\t%s\t%s\n" % (path, line, item.context, literal))
        print("  full list: %s" % listing)


def sync(found, above, taken, table, prune):
    """Rewrites the extracted section and returns the problems that should fail the run.
    A translation is only ever deleted by --prune."""
    used = found.used
    missing = sorted(k for k in used if k not in table and k not in taken)
    translated = [k for k in used if k in table and k not in taken]
    stale = sorted(k for k in table if k not in used and k not in taken)
    print("\n%s: %d translated, %d missing, %d stale (%s), %d defined above the header"
          % (STRINGS, len(translated), len(missing) + len(found.unresolved), len(stale),
             "removed" if prune else "kept", sum(1 for k in used if k in taken)))
    keep = sorted(translated + ([] if prune else stale))
    problems = [write_table(above + HEADER + "\n" + "".join("%s = %s;\n" % (quote(k), quote(table[k])) for k in keep))]
    for key in translated:
        reason = translation_error(key, table[key], any(is_format for _, is_format in used[key]))
        problems.append(reason and "BAD TRANSLATION %s = %s: %s" % (quote(key), quote(table[key]), reason))
    if stale:
        strings = {f.token[1].text(): s.where(f) for s, f in found.unreachable}
        print("\nTranslations whose key is no longer a LocalizedStringKey literal (%s):" % ("removed" if prune else "--prune deletes them"))
        for key in stale:
            print("  %s%s" % (quote(key), "   still a String at " + strings[key] if key in strings else ""))
        problems.append(None if prune else "%d stale translations" % len(stale))
    if missing:
        print("\nMissing translations (paste under the header and fill in):")
        for key in missing:
            print("%s = \"\";  /* %s */" % (quote(key), ", ".join(sorted({w for w, _ in used[key]})[:3])))
        problems.append("%d keys have no translation" % len(missing))
    if found.unresolved:
        print("\nNew literals whose interpolation the script cannot type; rerun with --stringsdata for the exact key:")
        for where, text in found.unresolved:
            print("  %s  \"%s\"" % (where, text))
        problems.append("%d literals need --stringsdata" % len(found.unresolved))
    return [p for p in problems if p]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--stringsdata", metavar="DIR", help="check against the compiler's .stringsdata files")
    parser.add_argument("--unreachable", metavar="FILE", help="write every unreachable Korean literal as TSV")
    parser.add_argument("--prune", action="store_true", help="delete translations whose key is no longer in the source")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    if not shutil.which("plutil"):
        sys.exit("this script needs plutil (macOS)")
    if args.selftest:
        return selftest()
    paths = glob.glob(os.path.join(ROOT, SOURCES, "**", "*.swift"), recursive=True)
    sources = [Source(os.path.relpath(path, ROOT)) for path in sorted(paths)]
    above, taken, table = read_table()
    resolved, problems = {}, []
    if args.stringsdata:
        resolved, problems = compare_with_compiler(sources, compiler_keys(sources, args.stringsdata))
    found = scan(sources, list(table) + list(taken), resolved)
    report(sources, found, "compiler" if args.stringsdata else "key already in the table", args.unreachable)
    failures = sync(found, above, taken, table, args.prune)
    if args.stringsdata:
        print("\nCompiler check: %d literals compared, %d problems" % (len(resolved), len(problems)))
    for problem in problems + failures:
        print(problem)
    return 1 if problems or failures else 0


def selftest():
    def keys(code):
        source = Source("selftest.swift", code)
        return [Key(f.token[1]).text() for f in source.found if id(f.token) in source.keys]

    assert keys(r'Text("설정")') == ["설정"]
    assert keys(r'Text(name); Text(verbatim: "가"); Text("가" + "나"); Text(title ?? "가"); Text(on ? "가" : name)') == []
    assert keys(r'Button(on ? "켜짐" : (dim ? "흐림" : "꺼짐")) {}') == ["켜짐", "흐림", "꺼짐"]
    assert keys(r'Text(["a": "가", "b": "나"][key] ?? "다")') == ["가", "나", "다"]
    assert keys(r'Text(offer.map { "\($0.price) 충전" } ?? " ")') == ["%@ 충전", " "]
    assert keys(r'LabeledContent("이름", value: "값"); view.accessibilityAction(named: "닫기") {}') == ["이름", "닫기"]
    assert keys(r'Text("\(items.count)개 중 \(a.count + b.count - 3)% \(name.formatted())")') == ["%lld개 중 %lld%% %@"]
    assert keys(r'Text("\(raw["n"] as? Int ?? 0)쪽 \(raw["n"] as? Int)쪽 \(x, specifier: "%.1f")점 \(d, format: .number)")') == ["%lld쪽 %@쪽 %.1f점 %@"]
    assert keys(r'Text("100% 완료 \"인용\"\n둘째 줄")') == ['100% 완료 "인용"\n둘째 줄']
    assert keys('Text("""\n    첫 줄 \\\n    이어서\n    둘째 \\(n) 줄\n    """)') == ["첫 줄 이어서\n둘째 %@ 줄"]
    assert keys(r'let p = #"\d+"#; Text(#"가\#(n)나"#) // Text("주석")') == ["가%@나"]
    assert keys('let r = #/[^"]+/#; Text("가")') == ["가"]
    assert keys(r'Text([1: "가", 2: "나",][k] ?? "다"); Text([c ? "라" : "마", "바"][i])') == ["가", "나", "다", "라", "마", "바"]
    assert keys(r'Text([c ? name : "가", "나"][i])') == []  # one String result makes the whole literal [String]

    def slots(code):  # the specifier of each interpolation, None where the shape does not tell
        return [s[0] for s in Key(Source("selftest.swift", code).found[0].token[1]).segments if isinstance(s, tuple)]
    assert slots(r'Text("\(-items.count) \(String(n)) \(a as? String ?? "") \(raw as? Int ?? 0) \(raw as? Int)")') == ["%lld", "%@", "%@", "%lld", "%@"]
    assert slots(r'Text("\(t as TimeInterval) \(Int(exactly: t)) \(Int(text)) \(Int(a * 100)) \(index + 1) \(x as Swift.Int)")') == [None] * 6
    source = Source("selftest.swift", r'Text("\(page)쪽"); fail("실패: \(on ? "예" : "아니오")")')
    key = Key(source.found[0].token[1])
    assert not key.exact and key.matches("%lld쪽") and key.matches("%@쪽") and not key.matches("%lld 쪽")
    contexts = [f.context for f in source.found if id(f.token) not in source.keys]
    assert contexts == ["fail(0)"] + ["inside \\(…) of another literal"] * 2, contexts
    assert parse_strings('/* "a" = "b"; */\n"k\\"1" = "v\\n1";\n// "c" = "d";\n"k2" = "v2";') == {'k"1': "v\n1", "k2": "v2"}
    assert parse_strings('"x" /* note */ = "\\UD83D\\UDE00";\r\n"x2" = y;\r\n') == {"x": "\U0001F600", "x2": "y"} and parse_strings("\n") == {}
    tricky = 'a"b\\c\nd\t\U0001F600 %@ \\n'
    assert parse_strings("%s = %s;" % (quote(tricky), quote("=" + tricky))) == {tricky: "=" + tricky}  # quote() round-trips
    assert translation_error("%lld쪽 중 %lld쪽", "Page %2$lld of %1$lld", True) is None
    assert translation_error("%@ %lld개", "%lld in %@", True) and translation_error("%lld%%", "%lld%", True)
    assert translation_error("크기 %lld%%", "Size %lld%%", True) is None and translation_error("%lld개", "100% of %lld", True)
    assert translation_error("%@ %lld개", "%2$lld in %1$@", True) is None
    assert translation_error("100% 완료", "100% done", False) is None and translation_error("100% 완료", "100%% done", False)
    print("selftest ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
