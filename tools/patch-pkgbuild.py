#!/usr/bin/env python3
"""Add local .patch files to an Arch PKGBUILD.

Does three things, all of which are easy to get subtly wrong by hand:

  1. appends each patch filename to source=()
  2. appends one 'SKIP' per patch to every checksum array present, keeping indices aligned
  3. inserts `patch -Np1 -i "$srcdir/<name>"` into the EXISTING prepare(), immediately after
     its first `cd`, preserving that line's indentation (Arch PKGBUILDs are tab-indented)

It refuses rather than guesses: if prepare() is missing, or a patch is already referenced,
it exits non-zero and changes nothing.

Usage, from the directory holding the PKGBUILD, with the patches already copied in beside it:

    python3 patch-pkgbuild.py hyprland-0.56.2-vmwgfx-dmabuf.patch
    python3 patch-pkgbuild.py --pkgrel-suffix .1 *.patch

Verify with `git diff` afterwards -- a `pkgctl repo clone` is a git repo.
"""
import argparse, os, re, shutil, sys

CHECKSUM_ARRAYS = ('sha256sums', 'sha512sums', 'sha1sums', 'b2sums', 'md5sums')


def find_array(text, name):
    """Return (start, end) covering `name=( ... )`, or None. Paren-aware, quote-aware."""
    m = re.search(r'^%s=\(' % re.escape(name), text, re.M)
    if not m:
        return None
    i, depth, quote = m.end() - 1, 0, None
    while i < len(text):
        c = text[i]
        if quote:
            if c == quote:
                quote = None
        elif c in '"\'':
            quote = c
        elif c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return m.start(), i + 1
        i += 1
    return None


def append_to_array(text, name, entries, indent):
    span = find_array(text, name)
    if not span:
        return text, False
    start, end = span
    body = text[start:end - 1].rstrip()
    added = '\n'.join('%s%s' % (indent, e) for e in entries)
    return text[:start] + body + '\n' + added + ')' + text[end:], True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('patches', nargs='+')
    ap.add_argument('--pkgbuild', default='PKGBUILD')
    ap.add_argument('--pkgrel-suffix', default='',
                    help="e.g. .1 -> pkgrel=3 becomes pkgrel=3.1, marking it a local build")
    ap.add_argument('--strip', default='1', help='patch -pN level (default 1)')
    args = ap.parse_args()

    if not os.path.exists(args.pkgbuild):
        sys.exit('error: %s not found -- run this from the directory holding it' % args.pkgbuild)

    names = [os.path.basename(p) for p in args.patches]
    text = original = open(args.pkgbuild).read()

    for n in names:
        if n in text:
            sys.exit('error: %s is already referenced in %s; nothing changed' % (n, args.pkgbuild))
        if not os.path.exists(n):
            sys.exit('error: %s is not in this directory -- copy it beside the PKGBUILD first' % n)

    # 1. source=()
    text, ok = append_to_array(text, 'source', names, ' ' * 8)
    if not ok:
        sys.exit('error: no source=() array found')

    # 2. every checksum array that exists, one SKIP per patch
    touched = []
    for arr in CHECKSUM_ARRAYS:
        text, ok = append_to_array(text, arr, ["'SKIP'"] * len(names), ' ' * (len(arr) + 2))
        if ok:
            touched.append(arr)
    if not touched:
        sys.exit('error: no checksum array found')

    # 3. into the existing prepare(), after its first cd, preserving indentation
    mp = re.search(r'^prepare\(\)\s*\{', text, re.M)
    if not mp:
        sys.exit('error: this PKGBUILD has no prepare(); add the patch calls by hand.\n'
                 '       Do not invent one -- you may be dropping fixes the build needs.')
    mcd = re.search(r'^([ \t]*)cd\s+\S+.*$', text[mp.end():], re.M)
    if not mcd:
        sys.exit("error: prepare() has no cd line; add the patch calls by hand")
    indent = mcd.group(1)
    insert_at = mp.end() + mcd.end() + 1
    lines = ''.join('%spatch -Np%s -i "$srcdir/%s"\n' % (indent, args.strip, n) for n in names)
    text = text[:insert_at] + lines + text[insert_at:]

    # 4. optional local-build marker
    if args.pkgrel_suffix:
        text, n = re.subn(r'^(pkgrel=\d+)$', r'\1%s' % args.pkgrel_suffix, text, count=1, flags=re.M)
        if not n:
            print('warning: could not bump pkgrel', file=sys.stderr)

    shutil.copyfile(args.pkgbuild, args.pkgbuild + '.orig')
    open(args.pkgbuild, 'w').write(text)
    print('patched %s (backup: %s.orig)' % (args.pkgbuild, args.pkgbuild))
    print('  source=()      += %s' % ', '.join(names))
    print('  %s += %d x SKIP' % ('/'.join(touched), len(names)))
    print('  prepare()      += %d patch line(s), indent %r' % (len(names), indent))
    print('\nNow run: git diff')


if __name__ == '__main__':
    main()
