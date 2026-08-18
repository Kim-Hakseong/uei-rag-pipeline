# uei-rag-pipeline

대용량 기술 매뉴얼(PDF)을 **구조 인식 섹션**으로 쪼개 로컬 RAG 로 검색하고,
그 근거를 **VSCode Continue 안에서 바로** 코딩에 쓰는 파이프라인. 완전 오프라인.

일반 문서 질의응답용 [`local-rag`](https://github.com/Kim-Hakseong/local-rag) 의 자매 프로젝트다.
저 쪽은 **AnythingLLM 에서 읽고 묻는** 용도, 이 쪽은 **에디터에서 코딩하는** 용도다.

---

## 왜 만들었나

수 MB 짜리 매뉴얼을 LLM 에 통째로 넣으려다 멈추는 일이 흔하다. 계산해 보면 당연하다.

| 문서 크기 | 토큰(영문 기준) | Qwen2.5-Coder 32K 대비 |
|---|---|---|
| 2 MB | 약 524,000 | **16배 초과** |
| 4 MB | 약 1,049,000 | **32배 초과** |

통째로 담으려면 KV 캐시만 59 GB 가 필요하다(0.115 MiB/토큰 실측 기준).
**어떤 소비자용 GPU 로도 불가능하다.** ctx 를 키워 풀 문제가 아니라 접근을 바꿔야 한다.

그렇다고 그냥 RAG 에 넣으면 이번엔 반대 문제가 난다. 실측:

```
질문: "Position Range Limit object definition"
 #1 score 0.4451  EN_7000_05052.md   "| LLB | Lo…"
 #2 score 0.4302  EN_7000_05052.md   "|  |  |  |…"
```

정답이 있는 문서는 아예 안 잡히고 표 파편만 나온다.
문서를 512자로 **균등 절단**하면 청크에 문맥이 없기 때문이다.

이 프로젝트는 그 사이를 메운다 — **문서 구조를 살려 쪼개고, 필요한 조각만 에디터로 보낸다.**

---

## 구조

```
        ┌─ 일반 모드 ─────────────────────────────┐
바탕화면 │  Qwen3-4B          → AnythingLLM 에서 질의 │   (local-rag)
아이콘   └────────────────────────────────────────┘
 2개     ┌─ UEI 모드 ──────────────────────────────┐
        │  Qwen2.5-Coder-7B  → VSCode Continue     │   (이 저장소)
        │    @uei → 컨텍스트 서버 → vector-search   │
        └────────────────────────────────────────┘
```

VRAM 8 GB 에서 두 모델을 동시에 올릴 수 없어(2.4 + 4.7 GB + KV) **전환식**이다.

### 파이프라인

```
매뉴얼 PDF
   │  kordoc --format chunks   (헤딩 breadcrumb + 표 독립 청크)
   ▼
split_manual.py               ← 이 저장소의 핵심
   │  헤딩 경계로 섹션 조립 → 크기 정규화 → 표 헤더 복제
   ▼
manuals-split/<문서>/NNN__<섹션>.md
   │  각 파일 첫 줄: "> 출처: <문서> · <경로> · p.<페이지>"
   ▼
AnythingLLM 워크스페이스 (bge-m3 임베딩)
   │  POST /api/v1/workspace/{slug}/vector-search   ← 답변 생성 없이 0.7초
   ▼
VSCode Continue  @uei
```

---

## 실측 (FAULHABER CANopen 매뉴얼 4.9 MB PDF)

UEI 매뉴얼 대신 공개 매뉴얼로 검증한 결과다.

| 항목 | 값 |
|---|---|
| kordoc 청크 | 3,432개 (5.8초) |
| **분할 섹션** | **208개** |
| 섹션 길이 | min 101 / **중앙 1,085** / max 2,990 |
| 3,000자 초과 | **0건** |
| 분포 | <500: 27 · 500–1500: 110 · 1500–3000: 71 |

분할 결과 예:

```markdown
> 출처: EN_7000_05048.pdf · 4.4.3 Torque controller > 4.4.3.1 · p.31

# 4.4.3 Torque controller

| Index | Subindex | Name | Type | Attr. | Default value | Meaning |
| --- | --- | --- | --- | --- | --- | --- |
| 0x2342 | 0x00 | Number of Entries | U8 | ro | 2 | Number of object entries |
```

표가 잘릴 때 **헤더 행을 각 조각에 복제**한다. 헤더 없는 표 조각은
`| 0x2342 | 0x00 | 2 |` 처럼 열 의미를 잃어 검색·인용 모두 쓸모없어지기 때문이다.

---

## 사용법

### 1. 매뉴얼 분할

```powershell
python scripts\split_manual.py --input manuals-inbox\UEI_PowerDNA.pdf --out-dir manuals-split
python scripts\split_manual.py --input manuals-inbox --dry-run     # 통계만
```

| 옵션 | 기본 | 뜻 |
|---|---|---|
| `--min-chars` | 400 | 이보다 작은 섹션은 다음과 병합 |
| `--max-chars` | 3000 | 이보다 크면 줄 경계에서 분할 (표는 헤더 복제) |
| `--drop-below` | 40 | 이보다 짧으면 버림 (목차 파편 등) |

종료 코드: `0` 성공 / `1` 일부 실패 / `2` 전제 불충족(kordoc 없음 등)

### 2. AnythingLLM 에 투입

`manuals-split/<문서>/*.md` 를 매뉴얼 전용 워크스페이스에 넣는다.
`_index.json` 은 넣지 않는다(기계 판독용).

### 3. 코딩

VSCode 에서 `@uei <찾을 내용>` — 매뉴얼 근거가 컨텍스트에 자동 삽입된다.
`.c` 예제 파일은 RAG 에 넣지 말고 Continue 의 `@codebase` 로 인덱싱한다.
예제 코드를 512자로 쪼개면 함수가 잘려 오히려 나빠진다.

---

## 상태

| 구성요소 | 상태 |
|---|---|
| `split_manual.py` | **동작 검증 완료** (공개 매뉴얼 4.9 MB) |
| `spec/paths.example.md` | 작성됨 |
| 컨텍스트 서버 (`:8099`) | **미구현** |
| Continue 설정 템플릿 | **미구현** |
| 프로파일 전환 (토글) | **미구현** |
| UEI 실매뉴얼 검증 | **미실행** — 문서가 있는 장비에서 수행 |
| Coder-7B ctx 실측 | **미실행** — VRAM 계수는 추정치 |

`spec/paths.md`, `manuals-inbox/`, `manuals-split/`, `*.c` 는 `.gitignore` 대상이다.
**매뉴얼 원본과 예제 코드는 저장소에 올리지 않는다.**

## 라이선스

MIT. 서드파티: [kordoc](https://github.com/chrisryugj/kordoc) (MIT) ·
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) ·
[AnythingLLM](https://github.com/Mintplex-Labs/anything-llm) (MIT) ·
Qwen2.5-Coder (Apache-2.0) · BGE-M3 (MIT)
