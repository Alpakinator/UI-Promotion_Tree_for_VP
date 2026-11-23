#!/usr/bin/env python3
"""Repository checks. The pre-commit hook, the pre-push hook and the release
workflow all run this file; every failure says what to do instead.

  python3 scripts/checks.py               check the staged files (what a commit would hold)
  python3 scripts/checks.py --rev REV     check a commit instead
      --lint-base REV                     luacheck fails only on warnings added since REV
                                          (default: HEAD, or REV's parent with --rev)
  python3 scripts/checks.py tag TAG       release tag checks, then the checks above on its commit
  python3 scripts/checks.py fix-md5 [DIR] [--dry-run]
                                          rewrite stale md5 values in DIR's .modinfo (default: repo root)
  python3 scripts/checks.py shipped [DIR] [-z]
                                          print the .modinfo and the files it lists: what ships
  python3 scripts/checks.py version [--rev REV]
                                          print the .modinfo version
"""
import fnmatch
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

LUA_FILE = re.compile(r"\.lua$")
FILE_ENTRY = re.compile(rb"<File\b([^>]*)>\s*([^<]*?)\s*</File>")
MD5_ATTR = re.compile(rb'\bmd5="([0-9A-Fa-f]*)"')
MOD_VERSION = re.compile(rb'<Mod\b[^>]*\bversion="(\d+)"')
MODINFO_NAME = re.compile(r"^(?P<base>.+) \(v (?P<version>\d+)\)\.modinfo$")
# Files that live only in the main checkout (CLAUDE.md says so; a published
# CLAUDE.md once had to be cut out of the history with filter-branch).
LOCAL_ONLY = ["CLAUDE.md", "devtools/"]


def git(*args, input_bytes=None, check=True):
    return subprocess.run(["git", *args], input=input_bytes, capture_output=True, check=check).stdout


# ---------------------------------------------------------------------------
# Where files come from: the index (default), a commit, or a plain directory.
# ---------------------------------------------------------------------------

class GitTree:
    def __init__(self, rev=None):
        self.rev = rev
        if rev is None:
            out = git("ls-files", "-z", "--cached")
        else:
            out = git("ls-tree", "-r", "-z", "--name-only", rev)
        self.paths = sorted({p for p in out.decode("utf-8").split("\0") if p})
        self._blobs = {}

    def label(self):
        return "the staged files" if self.rev is None else self.rev

    def read_many(self, paths):
        missing = [p for p in paths if p not in self._blobs]
        if missing:
            prefix = ":" if self.rev is None else self.rev + ":"
            data = git("cat-file", "--batch", input_bytes="".join(prefix + p + "\n" for p in missing).encode("utf-8"))
            pos = 0
            for path in missing:
                end = data.index(b"\n", pos)
                header = data[pos:end].split()
                if header[-1] == b"missing":
                    self._blobs[path] = None
                    pos = end + 1
                    continue
                size = int(header[2])
                self._blobs[path] = data[end + 1:end + 1 + size]
                pos = end + 1 + size + 1
        return [self._blobs[p] for p in paths]

    def read(self, path):
        return self.read_many([path])[0]


class DirTree:
    """A plain folder (a working tree or an installed copy). Lists only its
    top-level files, which is where the .modinfo is; reads any path."""

    def __init__(self, root):
        self.root = root
        self.paths = sorted(f for f in os.listdir(root) if os.path.isfile(os.path.join(root, f)))

    def label(self):
        return self.root

    def read(self, path):
        try:
            with open(os.path.join(self.root, path), "rb") as fh:
                return fh.read()
        except FileNotFoundError:
            return None

    def read_many(self, paths):
        return [self.read(p) for p in paths]


# ---------------------------------------------------------------------------
# The .modinfo
# ---------------------------------------------------------------------------

def md5_of(data):
    return hashlib.md5(data).hexdigest().upper()


def find_modinfo(tree, problems):
    found = [p for p in tree.paths if p.endswith(".modinfo") and "/" not in p]
    if len(found) != 1:
        problems.append("expected exactly one .modinfo at the top level, found %d (%s). Keep one, named "
                        "'UI - Promotion Tree for VP (v <version>).modinfo'." % (len(found), ", ".join(found) or "none"))
        return None
    return found[0]


def modinfo_entries(text):
    """(path, md5 or None, match) for every <File> entry."""
    entries = []
    for m in FILE_ENTRY.finditer(text):
        md5 = MD5_ATTR.search(m.group(1))
        path = m.group(2).decode("utf-8").replace("\\", "/")
        entries.append((path, md5.group(1).decode().upper() if md5 else None, m))
    return entries


def check_modinfo(tree, problems):
    name = find_modinfo(tree, problems)
    if not name:
        return
    text = tree.read(name)
    version = MOD_VERSION.search(text)
    named = MODINFO_NAME.match(name)
    if not version:
        problems.append('%s: no version="N" on <Mod>. Add it; the release tag is v<version>.' % name)
    elif not named:
        problems.append("%s: the file name must end in ' (v %s).modinfo', the version on <Mod>. Rename it with git mv."
                        % (name, version.group(1).decode()))
    elif named.group("version") != version.group(1).decode():
        problems.append('%s: the file name says v %s but <Mod version="%s">. A version bump changes both: '
                        "set the same number in the file name (git mv) and in version=."
                        % (name, named.group("version"), version.group(1).decode()))
    entries = modinfo_entries(text)
    listed = {path for path, _, _ in entries}
    blobs = tree.read_many([path for path, _, _ in entries])
    for (path, md5, _), data in zip(entries, blobs):
        if data is None:
            problems.append("%s lists %s, which is not in %s. Add the file, or remove its <File> entry."
                            % (name, path, tree.label()))
        elif md5 != md5_of(data):
            problems.append("%s: stale md5 for %s (listed %s, actual %s). Run: python3 scripts/checks.py fix-md5 "
                            "&& git add '%s'" % (name, path, md5 or "none", md5_of(data), name))
    shipped_dirs = {p.split("/")[0] + "/" for p in listed if "/" in p}
    for path in tree.paths:
        if any(path.startswith(d) for d in shipped_dirs) and path not in listed:
            problems.append('%s ships with the mod but %s does not list it, so the game ignores it. Add '
                            '<File md5="" import="1">%s</File> (import="1" for files other Lua include(), '
                            '"0" otherwise), then run: python3 scripts/checks.py fix-md5' % (path, name, path))


def fix_md5(root, dry_run):
    tree = DirTree(root)
    problems = []
    name = find_modinfo(tree, problems)
    if not name:
        sys.exit("\n".join(problems))
    path = os.path.join(root, name)
    with open(path, "rb") as fh:
        text = fh.read()
    changed = []

    def refresh(m):
        rel = m.group(2).decode("utf-8").replace("\\", "/")
        data = tree.read(rel)
        if data is None:
            return m.group(0)
        actual = md5_of(data).encode()
        attrs = m.group(1)
        md5 = MD5_ATTR.search(attrs)
        if md5 and md5.group(1).upper() == actual:
            return m.group(0)
        changed.append(rel)
        if md5:
            attrs = attrs[:md5.start(1)] + actual + attrs[md5.end(1):]
        else:
            attrs = b' md5="' + actual + b'"' + attrs
        return m.group(0).replace(m.group(1), attrs, 1)

    new_text = FILE_ENTRY.sub(refresh, text)
    for rel in changed:
        print("%s md5: %s" % ("would refresh" if dry_run else "refreshed", rel), file=sys.stderr)
    if changed and not dry_run:
        with open(path, "wb") as fh:
            fh.write(new_text)


def shipped(tree):
    problems = []
    name = find_modinfo(tree, problems)
    if not name:
        sys.exit("\n".join(problems))
    return [name] + [path for path, _, _ in modinfo_entries(tree.read(name))]


# ---------------------------------------------------------------------------
# Lua source rules
# ---------------------------------------------------------------------------

LONG_BRACKET = re.compile(r"\[(=*)\[")


def lua_code_only(src):
    """The source with comments blanked (newlines kept, so line numbers hold)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "-" and src.startswith("--", i):
            m = LONG_BRACKET.match(src, i + 2)
            if m:
                end = src.find("]" + m.group(1) + "]", m.end())
                end = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = src.find("\n", i)
                end = n if end < 0 else end
            out.append(re.sub(r"[^\n]", " ", src[i:end]))
            i = end
        elif c in "\"'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif c == "[" and LONG_BRACKET.match(src, i):
            m = LONG_BRACKET.match(src, i)
            end = src.find("]" + m.group(1) + "]", m.end())
            end = n if end < 0 else end + len(m.group(1)) + 2
            out.append(src[i:end])
            i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


PER_TREE_FIX = ("Nothing is stored per tree (stored rows and reviewed layouts were removed 2026-11-08, "
                "commit 5d514ec, so problems in the algorithm can't hide). Make the live search in "
                "LUA/PromotionTreeLayout.lua find this layout instead of storing it.")
PER_TREE_RULES = [
    # Both removed tables were generated files ("Generated; do not edit").
    ("generated data", True, re.compile(r"(?i)\bgenerated\b[^\n]*\b(do not|don't) (hand-)?edit")),
    # Stored rows: ["PROMOTION_DRILL_1"] = 4
    ("promotion placed by name", False,
     re.compile(r'(\[\s*"PROMOTION_\w+"\s*\]|[{,;]\s*PROMOTION_\w+)\s*=\s*-?\d')),
    # Reviewed layouts: {["type"]="PROMOTION_SHOCK_1",["x"]=82,["y"]=350}
    ("promotion placed by name", False,
     re.compile(r'type"?\]?\s*=\s*"PROMOTION_\w+"\s*,\s*\[?"?[xy]"?\]?\s*=\s*-?\d')),
    # Stored rows were keyed by a graph hash: ["04383d07-14-13"]
    ("tree keyed by graph hash", False, re.compile(r'"[0-9a-f]{8}-\d+-\d+"')),
    ("removed per-tree table", False,
     re.compile(r"\b(PromotionTreeStoredRows|PromotionReviewedLayouts?|StoredRows|ReviewedLayouts?)\b")),
]

# Since v28 the mod never refuses a tree. These are the two messages the panel
# may still show: an empty class, and both the live search and the emergency
# layout failing. v25-v27 refused trees "within the display limits".
ALLOWED_TREE_MESSAGES = {
    "No promotions are available for this unit class.",
    "This promotion tree could not be arranged.",
}
REFUSAL_FIX = ("The mod never refuses a tree (since v28). Give this failure a fallback that still draws every card "
               "(PromotionEmergencyLayout, DrawTreeLayoutBare, PipeManagerDrawRoutesSeparately) and print() the "
               "reason to the log instead of showing a message.")


def check_lua_rules(tree, problems):
    lua_paths = [p for p in tree.paths if LUA_FILE.search(p) and not p.startswith("devtools/")]
    for path, data in zip(lua_paths, tree.read_many(lua_paths)):
        if data is None:
            continue
        src = data.decode("utf-8", errors="replace")
        code = lua_code_only(src)
        for label, with_comments, pattern in PER_TREE_RULES:
            text = src if with_comments else code
            for m in pattern.finditer(text):
                hit = m.group(0).lstrip("{,; \t\r\n")
                problems.append("%s:%d: %s: %s. %s" % (path, line_of(text, m.end() - len(hit)), label,
                                                      " ".join(hit.split())[:80], PER_TREE_FIX))
                break
        for m in re.finditer(r"LayoutStatus\s*:\s*SetText\s*\(\s*([^)\s]*)", code):
            if m.group(1) != "message":
                problems.append("%s:%d: a new message on the tree panel (LayoutStatus:SetText(%s)). %s"
                                % (path, line_of(code, m.start()), m.group(1), REFUSAL_FIX))
        for m in re.finditer(r"\bunavailable\s*\(\s*(\"(?:[^\"\\]|\\.)*\"|[^)]*)\)", code):
            arg = m.group(1).strip()
            if code[max(0, m.start() - 9):m.start()].endswith("function "):
                continue
            if not (arg.startswith('"') and arg[1:-1] in ALLOWED_TREE_MESSAGES):
                problems.append("%s:%d: refusal message unavailable(%s). %s"
                                % (path, line_of(code, m.start()), arg[:80], REFUSAL_FIX))


def check_local_only(tree, problems):
    patterns = list(LOCAL_ONLY)
    exclude = git("rev-parse", "--git-path", "info/exclude", check=False).decode().strip()
    if exclude and os.path.exists(exclude):
        with open(exclude, encoding="utf-8") as fh:
            patterns += [ln.strip() for ln in fh if ln.strip() and not ln.startswith("#")]

    def matches(path, pattern):
        # gitignore rules, enough for exclude lines: "name" matches at any depth,
        # "a/b" is anchored at the top, a trailing "/" matches directories only.
        directory = pattern.endswith("/")
        core = pattern.strip("/")
        parts = path.split("/")
        if "/" in core:
            depth = core.count("/") + 1
            return fnmatch.fnmatchcase("/".join(parts[:depth]), core) and (len(parts) > depth or not directory)
        return any(fnmatch.fnmatchcase(part, core) for part in (parts[:-1] if directory else parts))

    for path in tree.paths:
        for pattern in (p for p in patterns if not p.startswith("!")):
            if matches(path, pattern):
                problems.append("%s is local only (%s, see .git/info/exclude) and must never be committed or "
                                "pushed. Unstage it: git rm --cached -r '%s'" % (path, pattern, path))
                break


# ---------------------------------------------------------------------------
# Lint: luacheck, failing only on warnings a change adds
# ---------------------------------------------------------------------------

TOP_LEVEL_SET = re.compile(r"^(?:function\s+([A-Za-z_]\w*)\s*\(|([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*=(?!=))",
                           re.M)
TOP_LEVEL_LOCAL = re.compile(r"^local\s+(?:function\s+)?([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)", re.M)
LUACHECK_LINE = re.compile(r"^(?P<file>.+?):(?P<line>\d+):(?P<col>\d+)(?:-\d+)?: (?:\((?P<code>[EW]\d+)\) )?(?P<msg>.*)$")
LINT_FIX = [
    ("W1", "declare it local, or if other files use it, define it at the top level of a LUA/ file "
           "(engine names belong in .luacheckrc)"),
    ("W2", "remove it, or name it _ when its position must stay"),
    ("W3", "remove the assignment or use the value"),
    ("W4", "rename the inner variable"),
    ("W5", "remove the dead or empty code"),
    ("E", "fix the syntax error"),
]


def mod_globals(sources):
    """Names the shipped Lua defines at its top level: the mod's cross-file globals."""
    names = set()
    for src in map(lua_code_only, sources):
        local = {n.strip() for m in TOP_LEVEL_LOCAL.finditer(src) for n in m.group(1).split(",")}
        for m in TOP_LEVEL_SET.finditer(src):
            for n in (m.group(1) or m.group(2)).split(","):
                if n.strip() not in local and n.strip() not in ("local", "return", "_"):
                    names.add(n.strip())
    return sorted(names)


def materialize(tree, paths, root):
    for path, data in zip(paths, tree.read_many(paths)):
        if data is None:
            continue
        target = os.path.join(root, path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "wb") as fh:
            fh.write(data)


def run_luacheck(luacheck, root, config, paths):
    paths = [p for p in paths if os.path.exists(os.path.join(root, p))]
    if not paths:
        return []
    sources = []
    for p in paths:
        with open(os.path.join(root, p), encoding="utf-8", errors="replace") as fh:
            sources.append(fh.read())
    cmd = [luacheck, "--formatter", "plain", "--codes", "--no-color", "--no-cache", "--config", config]
    names = mod_globals(sources)
    if names:
        cmd += ["--globals", *names]
    out = subprocess.run(cmd + ["--", *paths], cwd=root, capture_output=True, text=True)
    if out.returncode > 2:
        sys.exit("luacheck failed to run (exit %d):\n%s%s" % (out.returncode, out.stdout, out.stderr))
    warnings = []
    for line in out.stdout.splitlines():
        m = LUACHECK_LINE.match(line)
        if m:
            warnings.append(m)
    return warnings


def warning_key(m):
    return (m.group("file"), m.group("code") or "", re.sub(r"\bline \d+", "line N", m.group("msg")))


def check_lint(tree, base, problems, notes):
    lua_paths = [p for p in tree.paths if LUA_FILE.search(p) and not p.startswith("devtools/")]
    luacheck = shutil.which("luacheck")
    if not luacheck:
        notes.append("luacheck is not installed, so lint was skipped (install: sudo pacman -S luacheck). "
                     "Checked Lua syntax with luac5.1 instead.")
        check_syntax(tree, lua_paths, problems, notes)
        return
    if ".luacheckrc" not in tree.paths:
        notes.append("no .luacheckrc in %s; lint skipped" % tree.label())
        return
    base_tree = None
    if base and git("rev-parse", "-q", "--verify", base + "^{commit}", check=False).strip():
        base_tree = GitTree(base)
        base_lua = [p for p in base_tree.paths if LUA_FILE.search(p) and not p.startswith("devtools/")]
        if base_lua == lua_paths and base_tree.read_many(base_lua) == tree.read_many(lua_paths) \
                and base_tree.read(".luacheckrc") == tree.read(".luacheckrc"):
            return
    with tempfile.TemporaryDirectory() as tmp:
        now_root, base_root = os.path.join(tmp, "now"), os.path.join(tmp, "base")
        os.makedirs(now_root)
        os.makedirs(base_root)
        materialize(tree, lua_paths + [".luacheckrc"], now_root)
        config = os.path.join(now_root, ".luacheckrc")
        now = run_luacheck(luacheck, now_root, config, lua_paths)
        before = {}
        if base_tree:
            materialize(base_tree, base_lua, base_root)
            for m in run_luacheck(luacheck, base_root, config, base_lua):
                before[warning_key(m)] = before.get(warning_key(m), 0) + 1
        seen = {}
        for m in now:
            key = warning_key(m)
            seen[key] = seen.get(key, 0) + 1
            if seen[key] > before.get(key, 0):
                code = m.group("code") or "E"
                fix = next(text for prefix, text in LINT_FIX if code.startswith(prefix) or prefix == "E")
                problems.append("%s:%s:%s: (%s) %s: %s" % (m.group("file"), m.group("line"), m.group("col"),
                                                          code, m.group("msg"), fix))
        if base_tree is None:
            notes.append("nothing to compare lint with (%s): every luacheck warning counts as new"
                         % (base or "no earlier v* tag"))


def check_syntax(tree, lua_paths, problems, notes):
    luac = shutil.which("luac5.1")
    if not luac:
        notes.append("luac5.1 is not installed either: Lua syntax not checked")
        return
    with tempfile.TemporaryDirectory() as tmp:
        materialize(tree, lua_paths, tmp)
        for path in lua_paths:
            out = subprocess.run([luac, "-p", "--", path], cwd=tmp, capture_output=True, text=True)
            if out.returncode:
                problems.append("%s: fix the Lua syntax error" % re.sub(r"^\S*luac[\d.]*: ", "", out.stderr.strip()))


# ---------------------------------------------------------------------------
# Release tags
# ---------------------------------------------------------------------------

GIT_TEMPLATE = re.compile(r"(?m)^#\s*(Write a message for tag|Lines starting with '#' will be)")


def check_tag(tag, problems):
    if not git("rev-parse", "-q", "--verify", "refs/tags/" + tag, check=False).strip():
        problems.append("no tag %s. Create it with: scripts/tag-release NOTES.md" % tag)
        return
    if git("cat-file", "-t", "refs/tags/" + tag).strip() != b"tag":
        problems.append("%s is a lightweight tag; the release notes come from an annotated tag's message. "
                        "Recreate it: git tag -d %s && scripts/tag-release NOTES.md" % (tag, tag))
        return
    raw = git("cat-file", "tag", "refs/tags/" + tag).decode("utf-8", errors="replace")
    message = raw.split("\n\n", 1)[1] if "\n\n" in raw else ""
    message = message.split("-----BEGIN PGP SIGNATURE-----")[0]
    commit = git("rev-parse", "refs/tags/%s^{commit}" % tag).decode().strip()
    tree = GitTree(commit)
    name = find_modinfo(tree, problems)
    if name:
        version = MOD_VERSION.search(tree.read(name))
        if version and "v" + version.group(1).decode() != tag:
            problems.append('tag %s is on a commit whose .modinfo says version="%s". Bump version= and the '
                            ".modinfo file name, commit, and tag that commit v<version>."
                            % (tag, version.group(1).decode()))
    redo = "Recreate the tag: git tag -d %s && scripts/tag-release NOTES.md" % tag
    if not message.strip():
        problems.append("%s has an empty message; it becomes the release notes. %s" % (tag, redo))
    if GIT_TEMPLATE.search(message):
        problems.append("%s's message still holds git's '# Write a message for tag' template lines, which "
                        "would show in the release notes. %s" % (tag, redo))
    # git's default cleanup drops "### Heading" lines as comments, leaving
    # sections of bullets separated by bare blank lines (what happened to v27).
    blocks = [b for b in re.split(r"\n\s*\n", message.strip()) if b.strip()]
    bullet_blocks = [b for b in blocks if b.lstrip().startswith(("- ", "* "))]
    if not re.search(r"(?m)^#", message) and len(bullet_blocks) >= 2:
        problems.append("%s's notes have %d groups of bullets but no '#' heading: git stripped the headings as "
                        "comments (tag made without --cleanup=verbatim). %s" % (tag, len(bullet_blocks), redo))
    return commit


# ---------------------------------------------------------------------------

def run_checks(tree, lint_base):
    problems, notes = [], []
    check_local_only(tree, problems)
    check_modinfo(tree, problems)
    check_lua_rules(tree, problems)
    check_lint(tree, lint_base, problems, notes)
    return problems, notes


def report(problems, notes, what):
    for note in notes:
        print("note: " + note, file=sys.stderr)
    if problems:
        print("%d problem(s) in %s:" % (len(problems), what), file=sys.stderr)
        for p in problems:
            print("  " + p, file=sys.stderr)
        return 1
    return 0


def main(argv):
    def option(name, default=None):
        if name in argv:
            i = argv.index(name)
            value = argv[i + 1]
            del argv[i:i + 2]
            return value
        return default

    def flag(name):
        if name in argv:
            argv.remove(name)
            return True
        return False

    top = git("rev-parse", "--show-toplevel", check=False).decode().strip()
    command = argv.pop(0) if argv and not argv[0].startswith("-") else "check"
    if command == "fix-md5":
        dry = flag("--dry-run")
        fix_md5(argv[0] if argv else top, dry)
        return 0
    if command == "shipped":
        nul = flag("-z")
        tree = DirTree(argv[0]) if argv else GitTree()
        sys.stdout.write(("\0" if nul else "\n").join(shipped(tree)) + ("\0" if nul else "\n"))
        return 0
    if command == "version":
        rev = option("--rev")
        tree = GitTree(rev)
        problems = []
        name = find_modinfo(tree, problems)
        version = name and MOD_VERSION.search(tree.read(name))
        if not version:
            sys.exit("\n".join(problems) or "no version on <Mod> in " + str(name))
        print(version.group(1).decode())
        return 0
    os.chdir(top)
    lint_base = option("--lint-base")
    if command == "tag":
        tag = argv[0]
        # Lint against the previous release: what this release adds must be clean.
        lint_base = lint_base or git("describe", "--tags", "--abbrev=0", "--match", "v*", tag + "^",
                                     check=False).decode().strip() or None
        problems = []
        commit = check_tag(tag, problems)
        if commit:
            more, notes = run_checks(GitTree(commit), lint_base)
            problems += more
        else:
            notes = []
        return report(problems, notes, "tag " + tag)
    if command != "check":
        print(__doc__, file=sys.stderr)
        return 2
    rev = option("--rev")
    if rev:
        tree = GitTree(git("rev-parse", rev + "^{commit}").decode().strip())
        lint_base = lint_base or rev + "^"
    else:
        tree = GitTree()
        lint_base = lint_base or "HEAD"
    return report(*run_checks(tree, lint_base), what=tree.label())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
