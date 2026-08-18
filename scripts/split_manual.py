"""split_manual.py — 대용량 매뉴얼(PDF/HWP/DOCX)을 구조 인식 섹션 md 로 분할

목적
    수 MB 짜리 매뉴얼 1개를 통째로 임베딩하면 RAG 가 망가진다. 청크에 문맥이 없어
    "어느 섹션 이야기인지" 모르고, 문서 하나가 벡터 공간을 독점한다.
    이 스크립트는 kordoc 의 구조 청크(`--format chunks`)를 받아
    **헤딩 경로(breadcrumb) 단위 섹션 md 여러 개**로 재조립한다.

    각 산출 md 는 맨 위에 출처/경로/페이지를 심는다. 이 줄이 임베딩에 함께 들어가
    검색·인용 시 "몇 장 몇 절"인지 드러난다.

전제
    - kordoc 이 전역 설치돼 있고 `--format chunks` 를 지원한다 (4.7.2 확인).
    - Python 3.10+ / 표준 라이브러리만.
    - 네트워크 접근 없음.

사용법
    python scripts\\split_manual.py --input manuals-inbox\\UEI_PowerDNA.pdf --out-dir manuals-split
    python scripts\\split_manual.py --input manuals-inbox --out-dir manuals-split   # 폴더 일괄
    python scripts\\split_manual.py --input a.pdf --dry-run                          # 통계만

    종료 코드: 0 = 성공, 1 = 일부 실패, 2 = 전제 불충족

산출
    <out-dir>/<문서스템>/NNN__<섹션제목>.md    섹션 본문 (앞에 출처 헤더)
    <out-dir>/<문서스템>/_index.json           섹션 목록 + 페이지 + 길이 (기계 판독)

설계 근거
    - kordoc chunks 는 heading / text / table 세 타입으로 나오고, text·table 의
      `breadcrumb` 에 조상 헤딩 경로가 담긴다. heading 청크를 섹션 경계로 삼는다.
    - PDF 추출 특성상 `# 3.2.1` 처럼 **번호만 있고 제목이 없는 헤딩**이 흔하다.
      이 경우 이어지는 본문 첫 문장에서 제목을 보완한다.
    - 너무 잘면(min-chars 미만) 다음 섹션과 병합하고, 너무 크면(max-chars 초과)
      청크 경계에서 이어서 자른다. 문장 중간을 자르지 않는다.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import unicodedata
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PATHS_MD = REPO_ROOT / "spec" / "paths.md"

SUPPORTED_EXT = {".pdf", ".hwp", ".hwpx", ".hwpml", ".docx", ".xlsx", ".xls"}

# 섹션 크기 목표 — 실측으로 조정할 값이라 상수로 노출한다.
DEFAULT_MIN_CHARS = 400      # 이보다 작은 섹션은 다음 섹션과 병합
DEFAULT_MAX_CHARS = 3000     # 이보다 큰 섹션은 청크 경계에서 분할
HEADING_RE = re.compile(r"^(#{1,6})\s*(.*)$")


def read_spec_path(key: str) -> str | None:
    """spec/paths.md 의 `KEY = VALUE` 한 줄을 읽는다. 없으면 None."""
    if not PATHS_MD.is_file():
        return None
    text = PATHS_MD.read_text(encoding="utf-8-sig")
    m = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$", text, re.MULTILINE)
    if not m:
        return None
    v = m.group(1).strip()
    return None if v.startswith("<") or v.startswith("(") else v


def find_kordoc() -> str | None:
    """KORDOC_CMD 를 spec/paths.md 에서 읽고, 없으면 표준 전역 설치 위치를 확인한다.

    PATH 동적 탐색은 하지 않는다 — 어느 경로를 썼는지 불명확해지기 때문.
    """
    v = read_spec_path("KORDOC_CMD")
    if v and Path(v).is_file():
        return v
    fallback = Path.home() / "AppData" / "Roaming" / "npm" / "kordoc.cmd"
    return str(fallback) if fallback.is_file() else None


def run_kordoc_chunks(kordoc: str, src: Path) -> list[dict]:
    """kordoc --format chunks 실행. 셸 문자열 조립 없이 인자 리스트로 넘긴다."""
    argv = [kordoc, str(src), "--format", "chunks", "--silent"]
    proc = subprocess.run(argv, capture_output=True, timeout=1800, check=False)
    out = proc.stdout.decode("utf-8", errors="replace")
    err = proc.stderr.decode("utf-8", errors="replace")
    if not out.strip():
        raise RuntimeError(
            f"kordoc 이 빈 출력을 냈다 (exit {proc.returncode}). stderr: {err.strip()[:300]}"
        )
    data = json.loads(out)
    if isinstance(data, dict):
        data = data.get("chunks") or data.get("data") or []
    if not isinstance(data, list):
        raise RuntimeError("kordoc chunks 출력이 배열이 아니다")
    return data


def heading_info(text: str) -> tuple[int, str]:
    """heading 청크 텍스트에서 (레벨, 제목)을 뽑는다."""
    first = (text or "").strip().splitlines()
    if not first:
        return 0, ""
    m = HEADING_RE.match(first[0])
    if not m:
        return 0, first[0].strip()
    return len(m.group(1)), m.group(2).strip()


def looks_numeric_only(title: str) -> bool:
    """`3.2.1` 처럼 번호뿐이라 제목 구실을 못 하는지 판정."""
    t = (title or "").strip()
    if not t:
        return True
    return bool(re.fullmatch(r"[\d.\-–]+", t))


def slugify(text: str, limit: int = 60) -> str:
    """파일명 안전 슬러그. 한글은 보존한다(검색·식별에 유리)."""
    t = unicodedata.normalize("NFC", text or "")
    t = re.sub(r"[\\/:*?\"<>|]", "", t)          # Windows 금지 문자
    t = re.sub(r"\s+", "-", t.strip())
    t = re.sub(r"[^0-9A-Za-z가-힣._\-]", "", t)
    t = re.sub(r"-{2,}", "-", t).strip("-._")
    return t[:limit] or "section"


def build_sections(chunks: list[dict]) -> list[dict]:
    """heading 청크를 경계로 섹션을 조립한다."""
    sections: list[dict] = []
    cur: dict | None = None

    def flush() -> None:
        nonlocal cur
        if cur and cur["parts"]:
            cur["chars"] = sum(len(p) for p in cur["parts"])
            sections.append(cur)
        cur = None

    for ch in chunks:
        ctype = ch.get("type")
        text = (ch.get("text") or "").strip()
        page = ch.get("page")
        bc = [b for b in (ch.get("breadcrumb") or []) if b]

        if ctype == "heading":
            flush()
            level, title = heading_info(text)
            cur = {
                "title": title,
                "level": level,
                "breadcrumb": bc,
                "pages": set([page] if page is not None else []),
                "parts": [],
                "chars": 0,
                "title_needs_fix": looks_numeric_only(title),
            }
            continue

        if not text:
            continue
        if cur is None:
            # 첫 헤딩 이전의 본문 (표지·목차 등)
            cur = {
                "title": "머리말", "level": 0, "breadcrumb": bc,
                "pages": set(), "parts": [], "chars": 0, "title_needs_fix": False,
            }
        if page is not None:
            cur["pages"].add(page)
        cur["parts"].append(text)

    flush()

    # 번호뿐인 제목을 첫 '서술 문장'으로 보완.
    # 표 행(`| ... |`)이나 HTML 표는 제목으로 쓰지 않는다 — 열 이름이 제목이 되면
    # `4.4.3.1 Index | Subindex | Name | Type` 같은 쓸모없는 제목이 생긴다(실측).
    for s in sections:
        if not (s.get("title_needs_fix") and s["parts"]):
            continue
        for part in s["parts"]:
            head = part.strip()
            if head.startswith("|") or head.startswith("<table") or head.startswith("!["):
                continue
            first = re.split(r"[.\n]", head)[0].strip()
            first = re.sub(r"^[|#*\-\s]+", "", first)[:50].strip()
            if first and not first.startswith("|"):
                s["title"] = (s["title"] + " " + first).strip()
                break
    return sections


def split_oversized_part(part: str, max_chars: int) -> list[str]:
    """청크 하나가 max_chars 를 넘을 때 줄 경계에서 쪼갠다.

    표(`| ... |`)면 **헤더 행과 구분선을 각 조각에 복제**한다. 헤더 없는 표 조각은
    "| EQ-0219 | 24 | 2026-10-15 |" 처럼 열 의미를 잃어 검색·인용 모두 쓸모없어진다.
    (이전 프로젝트에서 '행 단위 청킹'을 다음 카드로 남겼던 문제의 실용 버전)
    """
    lines = part.splitlines()
    if len(lines) <= 1:
        # 줄바꿈이 없으면 더 쪼갤 경계가 없다. 그대로 둔다(잘라서 뜻을 깨지 않는다).
        return [part]

    is_table = sum(1 for ln in lines[:6] if ln.strip().startswith("|")) >= 2
    header: list[str] = []
    body = lines
    if is_table:
        header = [ln for ln in lines[:2] if ln.strip().startswith("|")]
        body = lines[len(header):]

    out: list[str] = []
    buf: list[str] = list(header)
    size = sum(len(x) + 1 for x in buf)
    for ln in body:
        if buf and len(buf) > len(header) and size + len(ln) + 1 > max_chars:
            out.append("\n".join(buf))
            buf = list(header)
            size = sum(len(x) + 1 for x in buf)
        buf.append(ln)
        size += len(ln) + 1
    if buf and len(buf) > len(header):
        out.append("\n".join(buf))
    return out or [part]


def merge_and_split(sections: list[dict], min_chars: int, max_chars: int) -> list[dict]:
    """너무 잔 섹션은 병합하고 너무 큰 섹션은 청크 경계에서 나눈다."""
    merged: list[dict] = []
    for s in sections:
        if merged and s["chars"] < min_chars and merged[-1]["chars"] + s["chars"] <= max_chars:
            prev = merged[-1]
            prev["parts"].extend(s["parts"])
            prev["pages"] |= s["pages"]
            prev["chars"] += s["chars"]
            prev.setdefault("merged_titles", []).append(s["title"])
            continue
        merged.append(dict(s))

    out: list[dict] = []
    for s in merged:
        if s["chars"] <= max_chars:
            out.append(s)
            continue
        # 청크 하나가 이미 max 를 넘으면 줄 경계에서 먼저 쪼갠다.
        expanded: list[str] = []
        for p in s["parts"]:
            expanded.extend(split_oversized_part(p, max_chars) if len(p) > max_chars else [p])

        buf: list[str] = []
        size = 0
        part_no = 1
        for p in expanded:
            if buf and size + len(p) > max_chars:
                out.append({**s, "parts": buf, "chars": size,
                            "title": f"{s['title']} ({part_no})"})
                part_no += 1
                buf, size = [], 0
            buf.append(p)
            size += len(p)
        if buf:
            title = f"{s['title']} ({part_no})" if part_no > 1 else s["title"]
            out.append({**s, "parts": buf, "chars": size, "title": title})
    return out


def page_range(pages: set) -> str:
    nums = sorted(p for p in pages if isinstance(p, int))
    if not nums:
        return "?"
    return str(nums[0]) if nums[0] == nums[-1] else f"{nums[0]}-{nums[-1]}"


def write_sections(sections: list[dict], src: Path, out_dir: Path) -> list[dict]:
    """섹션별 md 를 쓴다. 개행 LF 고정 — 산출물 해시를 플랫폼에 무관하게 유지."""
    doc_dir = out_dir / slugify(src.stem, 80)
    doc_dir.mkdir(parents=True, exist_ok=True)
    index: list[dict] = []

    for i, s in enumerate(sections, 1):
        path_parts = s["breadcrumb"] + ([s["title"]] if s["title"] else [])
        crumb = " > ".join(p for p in path_parts if p)
        pages = page_range(s["pages"])
        name = f"{i:03d}__{slugify(s['title'])}.md"
        fp = doc_dir / name

        header = (
            f"> 출처: {src.name} · {crumb or '(경로 없음)'} · p.{pages}\n\n"
            f"# {s['title'] or '(제목 없음)'}\n\n"
        )
        body = "\n\n".join(s["parts"]).strip() + "\n"
        with fp.open("w", encoding="utf-8", newline="") as fh:
            fh.write(header + body)

        index.append({
            "file": name, "title": s["title"], "breadcrumb": s["breadcrumb"],
            "pages": pages, "chars": len(body), "level": s["level"],
        })

    payload = {"source": src.name, "sections": index}
    with (doc_dir / "_index.json").open("w", encoding="utf-8", newline="") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    return index


def process(src: Path, out_dir: Path, kordoc: str, args) -> dict:
    chunks = run_kordoc_chunks(kordoc, src)
    sections = build_sections(chunks)
    sections = merge_and_split(sections, args.min_chars, args.max_chars)
    sections = [s for s in sections if s["chars"] >= args.drop_below]

    stat = {
        "source": src.name,
        "chunks": len(chunks),
        "sections": len(sections),
        "chars_total": sum(s["chars"] for s in sections),
    }
    if sections:
        sizes = sorted(s["chars"] for s in sections)
        stat["chars_min"] = sizes[0]
        stat["chars_median"] = sizes[len(sizes) // 2]
        stat["chars_max"] = sizes[-1]
    if not args.dry_run:
        write_sections(sections, src, out_dir)
    return stat


def main() -> int:
    ap = argparse.ArgumentParser(description="매뉴얼을 구조 인식 섹션 md 로 분할")
    ap.add_argument("--input", required=True, help="PDF/문서 파일 또는 폴더")
    ap.add_argument("--out-dir", default="manuals-split")
    ap.add_argument("--min-chars", type=int, default=DEFAULT_MIN_CHARS)
    ap.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    ap.add_argument("--drop-below", type=int, default=40,
                    help="이보다 짧은 섹션은 버린다(목차 파편 등)")
    ap.add_argument("--dry-run", action="store_true", help="파일을 쓰지 않고 통계만")
    args = ap.parse_args()

    kordoc = find_kordoc()
    if not kordoc:
        print("[split] kordoc 을 찾지 못했다. spec/paths.md 의 KORDOC_CMD 를 기입하거나 "
              "`npm install -g kordoc` 후 재시도할 것.", file=sys.stderr)
        return 2

    src = Path(args.input)
    if src.is_dir():
        targets = sorted(p for p in src.iterdir()
                         if p.is_file() and p.suffix.lower() in SUPPORTED_EXT)
    elif src.is_file():
        targets = [src]
    else:
        targets = []
    if not targets:
        print(f"[split] 처리할 문서가 없다: {src}", file=sys.stderr)
        return 2

    out_dir = Path(args.out_dir)
    print(f"[split] kordoc={kordoc}")
    print(f"[split] 대상 {len(targets)}건 / out={out_dir} / "
          f"min={args.min_chars} max={args.max_chars}"
          f"{' / DRY-RUN' if args.dry_run else ''}")

    failed = 0
    for t in targets:
        try:
            st = process(t, out_dir, kordoc, args)
            print(f"  OK  {t.name}: 청크 {st['chunks']} -> 섹션 {st['sections']}"
                  f" (길이 min {st.get('chars_min', '?')} / 중앙 {st.get('chars_median', '?')}"
                  f" / max {st.get('chars_max', '?')})")
        except Exception as exc:  # 실패를 삼키지 않는다 — 분류해 노출
            failed += 1
            print(f"  FAIL {t.name}: {type(exc).__name__}: {exc}", file=sys.stderr)

    print(f"[split] 완료. 성공 {len(targets) - failed} / 실패 {failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
