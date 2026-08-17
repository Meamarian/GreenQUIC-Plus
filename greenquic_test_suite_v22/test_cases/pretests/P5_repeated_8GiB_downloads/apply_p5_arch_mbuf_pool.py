#!/usr/bin/env python3
from __future__ import annotations

"""Set the packet-mbuf pool capacity in the disposable P5 DPDK datapath.

Architecture cases with four DPDK RX owners need at least 4 * 4096 RX mbufs
before any headroom. The previously observed 16383-mbuf pool is therefore one
mbuf short even before normal pool overhead. Runtime dpdk.ini does not expose
an RxMbufPoolSize/TxMbufPoolSize property, so the architecture experiment must
set this at build time instead of inventing unsupported INI keys.

This transformer rewrites the *second argument* (number of mbufs) of every real
C-code rte_pktmbuf_pool_create() call in the disposable datapath. Mentions in
comments and string/character literals are deliberately ignored. It is
architecture-only: build_p5_arch_profile.sh opts in with
P5_ARCH_MBUF_POOL_SIZE, while ordinary P5 Performance2 builds remain unchanged.
"""

import argparse
from pathlib import Path
import tempfile

MARKER_PREFIX = "GREENQUIC-P5-ARCH-MBUF-POOL-V2"
CALL = "rte_pktmbuf_pool_create"


def is_code_position(text: str, pos: int) -> bool:
    """Return True when pos is in C code, not a comment/string/char literal."""
    state = "code"
    escape = False
    i = 0
    while i < pos:
        ch = text[i]
        nxt = text[i + 1] if i + 1 < pos else ""
        if state == "line_comment":
            if ch == "\n":
                state = "code"
            i += 1
            continue
        if state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                i += 2
            else:
                i += 1
            continue
        if state in ("string", "char"):
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif (state == "string" and ch == '"') or (state == "char" and ch == "'"):
                state = "code"
            i += 1
            continue
        if ch == "/" and nxt == "/":
            state = "line_comment"
            i += 2
            continue
        if ch == "/" and nxt == "*":
            state = "block_comment"
            i += 2
            continue
        if ch == '"':
            state = "string"
        elif ch == "'":
            state = "char"
        i += 1
    return state == "code"


def matching_paren(text: str, open_pos: int) -> int:
    depth = 0
    quote: str | None = None
    escape = False
    i = open_pos
    while i < len(text):
        ch = text[i]
        if quote is not None:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise SystemExit("ERROR: unterminated rte_pktmbuf_pool_create() call")


def arg_spans(text: str, open_pos: int, close_pos: int) -> list[tuple[int, int]]:
    spans: list[tuple[int, int]] = []
    start = open_pos + 1
    depth = 0
    quote: str | None = None
    escape = False
    i = start
    while i < close_pos:
        ch = text[i]
        if quote is not None:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch in ('"', "'"):
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            spans.append((start, i))
            start = i + 1
        i += 1
    spans.append((start, close_pos))
    return spans


def transform_text(text: str, count: int) -> tuple[str, int]:
    if count < 16385:
        raise SystemExit(
            f"ERROR: architecture mbuf pool count={count} is below the 4x4096 descriptor requirement"
        )

    marker = f"/* {MARKER_PREFIX} count={count} */"
    # Remove an old V2 marker so rerunning the transformer can validate/rewrite
    # the actual calls rather than trusting marker text alone.
    lines = [ln for ln in text.splitlines(keepends=True) if MARKER_PREFIX not in ln]
    text = "".join(lines)

    replacements: list[tuple[int, int, str]] = []
    search = 0
    calls = 0
    ignored_noncode = 0
    while True:
        pos = text.find(CALL, search)
        if pos < 0:
            break
        if not is_code_position(text, pos):
            ignored_noncode += 1
            search = pos + len(CALL)
            continue
        before = text[pos - 1] if pos else ""
        after = text[pos + len(CALL)] if pos + len(CALL) < len(text) else ""
        if before.isalnum() or before == "_" or after.isalnum() or after == "_":
            search = pos + len(CALL)
            continue
        open_pos = pos + len(CALL)
        while open_pos < len(text) and text[open_pos].isspace():
            open_pos += 1
        if open_pos >= len(text) or text[open_pos] != "(":
            raise SystemExit("ERROR: code rte_pktmbuf_pool_create token has no opening parenthesis")
        close_pos = matching_paren(text, open_pos)
        spans = arg_spans(text, open_pos, close_pos)
        if len(spans) != 6:
            line = text.count("\n", 0, pos) + 1
            raise SystemExit(
                f"ERROR: expected 6 rte_pktmbuf_pool_create arguments, found {len(spans)} at source line {line}"
            )
        a, b = spans[1]
        field = text[a:b]
        leading = field[: len(field) - len(field.lstrip())]
        trailing = field[len(field.rstrip()):]
        replacements.append((a, b, f"{leading}{count}U{trailing}"))
        calls += 1
        search = close_pos + 1

    if calls == 0:
        raise SystemExit(
            "ERROR: disposable datapath contains no real C-code rte_pktmbuf_pool_create() call; refusing an unproven pool patch"
        )
    if calls > 4:
        raise SystemExit(f"ERROR: unexpected rte_pktmbuf_pool_create call count={calls} (>4)")

    for a, b, replacement in reversed(replacements):
        text = text[:a] + replacement + text[b:]
    text = marker + "\n" + text
    return text, calls


def patch(path: Path, count: int) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    new, calls = transform_text(text, count)
    path.write_text(new, encoding="utf-8")
    print(
        f"P5 ARCH MBUF POOL V2 PASS: count={count} "
        f"rte_pktmbuf_pool_create_calls={calls} path={path}"
    )


def self_test() -> None:
    fixture = '''/* Documentation may mention rte_pktmbuf_pool_create() without being code. */
// Another ignored mention: rte_pktmbuf_pool_create(fake)
static const char* pool_doc = "rte_pktmbuf_pool_create()";
static const char pool_ch = 'x';
static void f(void) {
    struct rte_mempool* a = rte_pktmbuf_pool_create(
        "rx", 16383, 128, 0, RTE_MBUF_DEFAULT_BUF_SIZE, rte_socket_id());
    struct rte_mempool* b = rte_pktmbuf_pool_create(
        make_name(0, 1),
        SOME_OLD_COUNT,
        cache_size(1, 2),
        0,
        RTE_MBUF_DEFAULT_BUF_SIZE,
        rte_socket_id());
}\n'''
    new, calls = transform_text(fixture, 32767)
    assert calls == 2
    assert new.count("32767U") == 2
    assert "16383" not in new
    assert "SOME_OLD_COUNT" not in new
    assert "Documentation may mention rte_pktmbuf_pool_create()" in new
    assert '"rte_pktmbuf_pool_create()"' in new
    assert new.count(MARKER_PREFIX) == 1
    again, calls2 = transform_text(new, 32767)
    assert calls2 == 2
    assert again == new
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / "datapath_raw_dpdk_linux.c"
        p.write_text(fixture, encoding="utf-8")
        patch(p, 32767)
        assert p.read_text(encoding="utf-8") == new
    print(
        "P5 ARCH MBUF POOL V2 SELF-TEST PASS: real-call parser + "
        "comment/string exclusion + idempotence"
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", type=Path)
    ap.add_argument("--count", type=int, default=32767)
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test:
        self_test()
        return 0
    if args.path is None:
        ap.error("PATH_TO_DATAPATH is required unless --self-test is used")
    patch(args.path, args.count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
