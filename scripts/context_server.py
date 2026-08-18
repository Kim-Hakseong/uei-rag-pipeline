"""context_server.py — VSCode Continue 용 매뉴얼 컨텍스트 서버

목적
    Continue 에서 `@uei <찾을 내용>` 을 치면 이 서버가 AnythingLLM 의 벡터 검색을
    대신 호출하고, 매뉴얼 근거를 에디터 컨텍스트로 돌려준다.
    사용자가 AnythingLLM 과 에디터 사이를 복붙할 필요가 없다.

    답변 생성은 하지 않는다 — 검색만 한다(0.7초). 코드 작성은 Continue 쪽 LLM 이 한다.

프로토콜 (Continue HttpContextProvider 실제 구현 기준)
    요청  POST <url>  {"query": str, "fullInput": str, "options": any, "workspacePath": str}
    응답  200  [{"name": str, "description": str, "content": str}]   (배열 또는 단일 객체)
    파싱 실패 시 Continue 는 경고만 남기고 빈 컨텍스트로 넘어간다 — 그래서 이 서버는
    실패해도 200 + 사람이 읽을 수 있는 안내 content 를 돌려준다(조용한 무응답 방지).

전제
    - AnythingLLM 이 떠 있고 매뉴얼이 임베딩된 워크스페이스가 있다.
    - spec/paths.md 에 ANYTHINGLLM_API_KEY / UEI_WORKSPACE 가 기입돼 있다.
      키 발급: AnythingLLM 설정 > API Keys, 또는
      `curl -X POST http://127.0.0.1:3001/api/system/generate-api-key`
    - Python 3.10+ / **표준 라이브러리만**. 네트워크는 127.0.0.1 루프백만.

사용법
    python scripts\\context_server.py                 # :8099 기동
    python scripts\\context_server.py --port 8099 --top-n 6
    python scripts\\context_server.py --self-test     # 기동 없이 검색 1회 점검

    종료 코드: 0 정상 종료 / 2 전제 불충족

보안
    127.0.0.1 에만 바인딩한다. 외부에서 접근할 수 없다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PATHS_MD = REPO_ROOT / "spec" / "paths.md"

DEFAULT_PORT = 8099
DEFAULT_TOP_N = 6
DEFAULT_THRESHOLD = 0.15
# 한 청크가 길면 에디터 컨텍스트를 잡아먹는다. Continue 쪽 ctx 예산을 지키려 자른다.
MAX_CHARS_PER_HIT = 1800
META_RE = re.compile(r"<document_metadata>[\s\S]*?</document_metadata>\s*", re.MULTILINE)
SOURCE_RE = re.compile(r"^>\s*출처:\s*(.+)$", re.MULTILINE)


def read_spec(key: str, default: str | None = None) -> str | None:
    """spec/paths.md 의 `KEY = VALUE` 를 읽는다. 플레이스홀더는 미기입으로 본다."""
    if not PATHS_MD.is_file():
        return default
    text = PATHS_MD.read_text(encoding="utf-8-sig")
    m = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.+?)\s*$", text, re.MULTILINE)
    if not m:
        return default
    v = m.group(1).strip()
    if v.startswith("<") or v.startswith("("):
        return default
    return v


class Config:
    def __init__(self, args) -> None:
        self.base = (read_spec("ANYTHINGLLM_URL") or "http://127.0.0.1:3001").rstrip("/")
        self.api_key = read_spec("ANYTHINGLLM_API_KEY")
        self.workspace = args.workspace or read_spec("UEI_WORKSPACE") or "uei-manual"
        self.top_n = args.top_n
        self.threshold = args.threshold

    def missing(self) -> list[str]:
        miss = []
        if not self.api_key:
            miss.append("ANYTHINGLLM_API_KEY")
        return miss


def vector_search(cfg: Config, query: str) -> list[dict]:
    """AnythingLLM 벡터 검색. 답변 생성 없이 근거만 받는다."""
    url = f"{cfg.base}/api/v1/workspace/{cfg.workspace}/vector-search"
    payload = json.dumps({
        "query": query,
        "topN": cfg.top_n,
        "scoreThreshold": cfg.threshold,
    }).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, method="POST",
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {cfg.api_key}",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = resp.read().decode("utf-8", errors="replace")
    data = json.loads(body)
    return data.get("results") or data.get("sources") or []


def clean_chunk(text: str) -> str:
    """AnythingLLM 이 붙인 <document_metadata> 블록을 걷어낸다.

    그 블록은 파일명·업로드 시각이라 코딩에 쓸모가 없고 컨텍스트만 차지한다.
    분할 산출물의 `> 출처:` 줄은 남긴다 — 그게 진짜 근거 위치다.
    """
    t = META_RE.sub("", text or "").strip()
    return t


def title_for(hit: dict, cleaned: str) -> str:
    """근거 위치를 한 줄로. `> 출처:` 줄이 있으면 그걸 쓴다(split_manual.py 산출물)."""
    m = SOURCE_RE.search(cleaned)
    if m:
        return m.group(1).strip()
    return (hit.get("title") or hit.get("metadata", {}).get("title") or "manual").strip()


def build_items(cfg: Config, query: str, hits: list[dict]) -> list[dict]:
    """검색 결과를 Continue ContextItem 배열로."""
    if not hits:
        return [{
            "name": "UEI (검색 결과 없음)",
            "description": f"'{query}' 에 대한 매뉴얼 근거를 찾지 못했다",
            "content": (
                f"매뉴얼 워크스페이스 '{cfg.workspace}' 에서 '{query}' 에 해당하는 내용을 찾지 못했습니다.\n\n"
                "확인할 것:\n"
                "1. 워크스페이스에 매뉴얼이 실제로 임베딩돼 있는지 (문서 관리 화면에서 목록 확인)\n"
                "2. 인덱스 번호만 쓰지 말고 문서에 적힌 명칭을 함께 넣을 것\n"
                "   예: '0x607B' (실패) → 'Position Range Limit 오브젝트' (성공)\n"
            ),
        }]

    items: list[dict] = []
    for i, hit in enumerate(hits, 1):
        cleaned = clean_chunk(hit.get("text", ""))
        if not cleaned:
            continue
        if len(cleaned) > MAX_CHARS_PER_HIT:
            cleaned = cleaned[:MAX_CHARS_PER_HIT] + "\n… (이하 생략)"
        score = hit.get("score")
        where = title_for(hit, cleaned)
        items.append({
            "name": f"UEI {i}. {where[:70]}",
            "description": f"유사도 {score:.4f}" if isinstance(score, (int, float)) else "매뉴얼 근거",
            "content": f"[매뉴얼 근거 {i}/{len(hits)}] {where}\n\n{cleaned}",
        })
    return items or [{
        "name": "UEI (빈 청크)",
        "description": "검색은 됐으나 내용이 비었다",
        "content": "검색 결과는 있었으나 본문이 비어 있습니다. 임베딩 상태를 확인하세요.",
    }]


class Handler(BaseHTTPRequestHandler):
    cfg: Config = None  # main 에서 주입

    def _send(self, code: int, obj) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path.rstrip("/") in ("/health", ""):
            self._send(200, {"status": "ok", "workspace": self.cfg.workspace,
                             "topN": self.cfg.top_n})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        try:
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8", errors="replace") if length else "{}"
            req = json.loads(raw or "{}")
        except (ValueError, json.JSONDecodeError) as exc:
            self._send(200, [{"name": "UEI (요청 오류)", "description": str(exc),
                              "content": f"요청 본문을 해석하지 못했습니다: {exc}"}])
            return

        # Continue 는 query 가 비어도 fullInput 을 보낸다. 빈 질의는 fullInput 으로 보완.
        query = (req.get("query") or "").strip() or (req.get("fullInput") or "").strip()
        if not query:
            self._send(200, [{
                "name": "UEI (질의 없음)",
                "description": "검색어가 비었다",
                "content": "@uei 뒤에 찾을 내용을 적어주세요. 예: @uei 인코더 분해능 설정",
            }])
            return

        try:
            hits = vector_search(self.cfg, query)
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")[:200]
            self._send(200, [{
                "name": "UEI (검색 실패)",
                "description": f"HTTP {exc.code}",
                "content": (
                    f"AnythingLLM 벡터 검색이 HTTP {exc.code} 로 실패했습니다.\n{detail}\n\n"
                    "403 이면 spec/paths.md 의 ANYTHINGLLM_API_KEY 를 확인하세요.\n"
                    "400 이면 UEI_WORKSPACE 슬러그가 실제 워크스페이스와 다를 수 있습니다."
                ),
            }])
            return
        except Exception as exc:  # 연결 거부 등 — 삼키지 않고 사람이 읽을 안내로 노출
            self._send(200, [{
                "name": "UEI (연결 실패)",
                "description": type(exc).__name__,
                "content": (
                    f"AnythingLLM({self.cfg.base}) 에 연결하지 못했습니다: {exc}\n\n"
                    "AnythingLLM 이 실행 중인지, 포트가 3001 인지 확인하세요."
                ),
            }])
            return

        self._send(200, build_items(self.cfg, query, hits))

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("[ctx] %s - %s\n" % (self.address_string(), fmt % args))


def self_test(cfg: Config, query: str) -> int:
    print(f"[ctx] self-test: {cfg.base} / workspace={cfg.workspace} / topN={cfg.top_n}")
    miss = cfg.missing()
    if miss:
        print(f"[ctx] 전제 불충족 — spec/paths.md 에 {', '.join(miss)} 기입 필요", file=sys.stderr)
        return 2
    try:
        hits = vector_search(cfg, query)
    except Exception as exc:
        print(f"[ctx] 검색 실패: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    print(f"[ctx] 결과 {len(hits)}건")
    for item in build_items(cfg, query, hits):
        print(f"  - {item['name']}  ({item['description']})")
        print(f"      {item['content'][:110].replace(chr(10), ' ')}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description="Continue 용 UEI 매뉴얼 컨텍스트 서버")
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--workspace", default=None, help="기본값은 spec/paths.md 의 UEI_WORKSPACE")
    ap.add_argument("--top-n", type=int, default=DEFAULT_TOP_N)
    ap.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    ap.add_argument("--self-test", action="store_true", help="기동하지 않고 검색 1회 점검")
    ap.add_argument("--query", default="encoder resolution", help="--self-test 용 질의")
    args = ap.parse_args()

    cfg = Config(args)
    if args.self_test:
        return self_test(cfg, args.query)

    miss = cfg.missing()
    if miss:
        print(f"[ctx] 전제 불충족 — spec/paths.md 에 {', '.join(miss)} 기입 필요", file=sys.stderr)
        print("[ctx] 키 발급: curl -X POST http://127.0.0.1:3001/api/system/generate-api-key",
              file=sys.stderr)
        return 2

    Handler.cfg = cfg
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"[ctx] listening on http://127.0.0.1:{args.port}")
    print(f"[ctx] workspace={cfg.workspace} topN={cfg.top_n} threshold={cfg.threshold}")
    print("[ctx] Continue 설정: docs/continue-config.md 참조. 종료는 Ctrl+C.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[ctx] 종료")
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
