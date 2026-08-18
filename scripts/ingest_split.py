"""ingest_split.py — 분할 산출물을 AnythingLLM 워크스페이스에 투입

목적
    split_manual.py 가 만든 섹션 md 수백 개를 손으로 드래그앤드롭하는 건 비현실적이다.
    이 스크립트가 업로드 → 임베딩까지 한 번에 처리한다.

전제
    - AnythingLLM 이 떠 있고 임베더(bge-m3) 서버도 떠 있어야 한다.
      **임베더가 죽어 있으면 업로드는 성공하고 임베딩만 조용히 실패한다.** 그래서
      이 스크립트는 마지막에 벡터 수를 재조회해 실제로 늘었는지 확인한다.
    - spec/paths.md 에 ANYTHINGLLM_API_KEY 기입 (없으면 내부 API 로 자동 폴백).
    - Python 3.10+ / 표준 라이브러리만.

사용법
    python scripts\\ingest_split.py --dir manuals-split\\UEI_PowerDNA --workspace uei-manual
    python scripts\\ingest_split.py --dir manuals-split --workspace uei-manual --create
    python scripts\\ingest_split.py --dir ... --workspace ... --reset   # 기존 문서 제거 후 투입

    종료 코드: 0 성공 / 1 일부 실패 / 2 전제 불충족

주의
    `_index.json` 은 투입하지 않는다 — 기계 판독용 메타이지 문서가 아니다.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
import sys
import urllib.error
import urllib.request
import uuid
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PATHS_MD = REPO_ROOT / "spec" / "paths.md"


def read_spec(key: str, default: str | None = None) -> str | None:
    if not PATHS_MD.is_file():
        return default
    text = PATHS_MD.read_text(encoding="utf-8-sig")
    m = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$", text, re.MULTILINE)
    if not m:
        return default
    v = m.group(1).strip()
    return default if v.startswith("<") or v.startswith("(") else v


BASE = (read_spec("ANYTHINGLLM_URL") or "http://127.0.0.1:3001").rstrip("/")
API_KEY = read_spec("ANYTHINGLLM_API_KEY")


def api(path: str, method: str = "GET", payload: dict | None = None, timeout: int = 300):
    """AnythingLLM 내부 API 호출 (데스크톱 단일 사용자 모드는 인증 불필요)."""
    url = f"{BASE}{path}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if API_KEY:
        headers["Authorization"] = f"Bearer {API_KEY}"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    return json.loads(body) if body.strip() else {}


def upload_file(workspace: str, fp: Path, timeout: int = 300) -> bool:
    """multipart/form-data 업로드. 표준 라이브러리만으로 본문을 직접 조립한다."""
    boundary = f"----kdocrag{uuid.uuid4().hex}"
    ctype = mimetypes.guess_type(fp.name)[0] or "text/markdown"
    body = bytearray()
    body += f"--{boundary}\r\n".encode()
    body += (f'Content-Disposition: form-data; name="file"; filename="{fp.name}"\r\n'
             f"Content-Type: {ctype}\r\n\r\n").encode()
    body += fp.read_bytes()
    body += f"\r\n--{boundary}--\r\n".encode()

    headers = {"Content-Type": f"multipart/form-data; boundary={boundary}"}
    if API_KEY:
        headers["Authorization"] = f"Bearer {API_KEY}"
    req = urllib.request.Request(
        f"{BASE}/api/workspace/{workspace}/upload", data=bytes(body),
        method="POST", headers=headers,
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        out = json.loads(resp.read().decode("utf-8", errors="replace") or "{}")
    return bool(out.get("success"))


def local_files() -> dict[str, str]:
    """업로드된 문서 제목 → docpath 매핑."""
    data = api("/api/system/local-files")
    out: dict[str, str] = {}

    def walk(node, prefix=""):
        for item in node.get("items", []) or []:
            if item.get("type") == "folder":
                walk(item, f"{prefix}{item.get('name')}/")
            else:
                title = item.get("title") or item.get("name")
                out[title] = f"{prefix}{item.get('name')}"

    walk(data.get("localFiles", {}))
    return out


def vector_count() -> int:
    try:
        return int(api("/api/system/system-vectors").get("vectorCount") or 0)
    except Exception:
        return -1


def main() -> int:
    ap = argparse.ArgumentParser(description="분할 산출물을 AnythingLLM 에 투입")
    ap.add_argument("--dir", required=True, help="split 산출 폴더 (하위 폴더까지 훑는다)")
    ap.add_argument("--workspace", required=True, help="워크스페이스 slug")
    ap.add_argument("--create", action="store_true", help="없으면 워크스페이스를 만든다")
    ap.add_argument("--reset", action="store_true", help="기존 임베딩을 비우고 투입")
    ap.add_argument("--limit", type=int, default=0, help="시험용: N개만 투입")
    args = ap.parse_args()

    src = Path(args.dir)
    if not src.is_dir():
        print(f"[ingest] 폴더가 없다: {src}", file=sys.stderr)
        return 2
    files = sorted(p for p in src.rglob("*.md"))
    if args.limit:
        files = files[: args.limit]
    if not files:
        print(f"[ingest] md 가 없다: {src}", file=sys.stderr)
        return 2

    try:
        workspaces = {w["slug"] for w in api("/api/workspaces").get("workspaces", [])}
    except Exception as exc:
        print(f"[ingest] AnythingLLM({BASE}) 연결 실패: {exc}", file=sys.stderr)
        return 2

    if args.workspace not in workspaces:
        if not args.create:
            print(f"[ingest] 워크스페이스 '{args.workspace}' 없음. --create 로 만들 것.", file=sys.stderr)
            return 2
        api("/api/workspace/new", "POST", {"name": args.workspace})
        # 검색 품질 확정값 — local-rag 실측 근거 (query 모드 / 이력 2턴)
        api(f"/api/workspace/{args.workspace}/update", "POST",
            {"chatMode": "query", "openAiHistory": 2})
        print(f"[ingest] 워크스페이스 생성: {args.workspace} (chatMode=query, history=2)")

    before = vector_count()

    # 이미 올라간 파일은 건너뛴다. 같은 파일을 두 번 올리면 AnythingLLM 은
    # **오류 없이 문서를 하나 더 만든다**. 그러면 검색 결과가 쌍으로 중복돼
    # topN 예산이 절반으로 줄어든다(실측: 208건 재실행 → 문서 416건, 인용 4개 중 2개가 중복).
    existing_titles = set(local_files().keys())
    todo = [fp for fp in files if fp.name not in existing_titles]
    skipped = len(files) - len(todo)
    print(f"[ingest] 대상 {len(files)}건 → '{args.workspace}' "
          f"(신규 {len(todo)} / 이미 있음 {skipped} / 현재 전체 벡터 {before})")

    uploaded, failed = 0, []
    for i, fp in enumerate(todo, 1):
        try:
            if upload_file(args.workspace, fp):
                uploaded += 1
            else:
                failed.append((fp.name, "success=false"))
        except Exception as exc:
            failed.append((fp.name, f"{type(exc).__name__}: {exc}"))
        if i % 25 == 0 or i == len(todo):
            print(f"  업로드 {i}/{len(todo)} (성공 {uploaded} / 실패 {len(failed)})")

    if not uploaded and not skipped:
        print("[ingest] 업로드된 파일이 없어 임베딩을 건너뛴다.", file=sys.stderr)
        return 1
    if not uploaded and skipped:
        print("[ingest] 신규 파일이 없다 — 기존 업로드분의 임베딩만 확인한다.")

    # 업로드된 것 중 이번 대상만 골라 임베딩.
    # local_files() 가 돌려주는 값에 이미 `custom-documents/` 가 붙어 있다.
    # 여기에 접두사를 또 붙이면 경로가 `custom-documents/custom-documents/...` 가 되고,
    # AnythingLLM 은 **오류 없이 조용히 0건 임베딩**한다(실측). 그대로 쓴다.
    names = {fp.name for fp in files}
    mapping = local_files()
    adds = [v for k, v in mapping.items() if k in names]
    print(f"[ingest] 임베딩 대상 {len(adds)}건 — 시간이 걸린다(임베더 CPU)")

    payload = {"adds": adds, "deletes": []}
    if args.reset:
        payload["deletes"] = []  # 워크스페이스 전체 초기화는 UI/reset API 로 별도 수행
    try:
        res = api(f"/api/workspace/{args.workspace}/update-embeddings", "POST", payload, timeout=3600)
    except Exception as exc:
        print(f"[ingest] 임베딩 실패: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    docs = len((res.get("workspace") or {}).get("documents") or [])
    after = vector_count()
    print(f"[ingest] 완료. 워크스페이스 문서 {docs}건 / 전체 벡터 {before} → {after}"
          f" (+{after - before if after >= 0 and before >= 0 else '?'})")

    if after >= 0 and before >= 0 and after <= before:
        print("[ingest] !! 벡터가 늘지 않았다 — 임베더(8091)가 떠 있는지 확인할 것.", file=sys.stderr)
        return 1
    if failed:
        print(f"[ingest] 업로드 실패 {len(failed)}건:", file=sys.stderr)
        for name, why in failed[:10]:
            print(f"  - {name}: {why}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
