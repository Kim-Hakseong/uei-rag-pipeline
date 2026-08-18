# uei-rag-pipeline

대용량 기술 매뉴얼(PDF)을 **구조 인식 섹션**으로 쪼개 로컬 RAG 로 검색하고,
그 근거를 **VSCode Continue 안에서 바로** 코딩에 쓰는 파이프라인. 완전 오프라인.

**처음이라면 → [QUICKSTART.md](QUICKSTART.md)** (local-rag 설치 후 10분)nn일반 문서 질의응답용 [`local-rag`](https://github.com/Kim-Hakseong/local-rag) 의 자매 프로젝트다.
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

### A/B — 분할이 검색을 실제로 바꾸는가

같은 문서, 같은 질문, 같은 임베더(bge-m3). **통짜 md** 워크스페이스와
**분할 산출물** 워크스페이스만 다르다.

| 질문 | 통짜 md | 구조 분할 |
|---|---|---|
| `Position Range Limit object definition` | 0.4451 — 약어표·목차 파편 | **0.5788** — `0x607A Target Position` 오브젝트 표 |
| `encoder resolution setting` | 0.5424 — 무관한 표 | **0.7043** — *"In the object 0x2315.02, set the encoder resolution to…"* |

유사도가 오른 것보다 **가져온 내용이 답에 해당한다는 점**이 중요하다.
통짜 쪽은 네 건 모두 파편이었고, 분할 쪽 1위는 설정 절차 문단이었다.

컨텍스트 서버를 거치면 근거 위치가 파일명으로 드러난다:

```
UEI 1. 055__Tab.-23-Configuration-of-the-encoder-type-in-object-0x2315.0.md  (유사도 0.7043)
```

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

### 0. 준비 (한 번만)

```powershell
copy spec\paths.example.md spec\paths.md    # 열어서 경로를 채운다
# AnythingLLM API 키 발급
curl -X POST http://127.0.0.1:3001/api/system/generate-api-key
```

`spec/paths.md` 는 `.gitignore` 대상이라 개인 경로·키가 저장소에 올라가지 않는다.

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

```powershell
python scripts\ingest_split.py --dir manuals-split --workspace uei-manual --create
```

업로드 → 임베딩 → **벡터 수 재조회로 실제 반영 확인**까지 한다.
임베더(8091)가 죽어 있으면 업로드는 성공하고 임베딩만 조용히 실패하기 때문이다.
이미 올라간 파일은 건너뛴다(중복 업로드 방지).
`_index.json` 은 투입하지 않는다 — 기계 판독용 메타이지 문서가 아니다.

### 3. 코딩

```powershell
Start-UEI-Mode.bat      # 8090 을 coder 로 전환 + 임베더 + @uei 서버
```

VSCode 에서:

```
@uei 인코더 분해능 설정 레지스터

위 근거대로 초기화 함수를 작성해줘. 스타일은 @codebase 예제를 따라줘.
```

- `.c` 예제는 **RAG 에 넣지 않는다.** Continue 의 `@codebase` 로 인덱싱한다.
  예제 코드를 512자로 쪼개면 함수가 잘려 오히려 나빠진다.
- 설정은 [`docs/continue-config.md`](docs/continue-config.md).
- 끝나면 `Stop-UEI-Mode.bat` (8090/8091/8099 만 내린다. VSCode·AnythingLLM 은 그대로).

---

## 상태

| 구성요소 | 상태 |
|---|---|
| `split_manual.py` | **검증 완료** — 4.9 MB PDF → 208 섹션 |
| `ingest_split.py` | **검증 완료** — 208건 투입, +976 벡터 |
| `context_server.py` | **검증 완료** — self-test 로 근거 반환 확인 |
| `serve_coder.ps1` / 배치 2개 | 작성됨 — **coder 모델이 없어 실기동 미검증** |
| `docs/continue-config.md` | 작성됨 — **Continue 실연동 미검증** |
| A/B 검색 개선 | **실측 완료** (위 표) |
| UEI 실매뉴얼 | **미실행** — 문서가 있는 장비에서 |
| Coder-7B ctx / VRAM | **미실행** — 계수는 추정치 |

### 이 저장소가 아직 증명하지 못한 것

- **Coder-7B 가 8GB 에서 ctx 32768 로 실제로 뜨는지.** KV 계수 0.045 MiB/토큰은
  Qwen3-4B 실측(0.115)을 구조비로 환산한 값이라 실측이 아니다.
- **Continue 가 `@uei` 를 실제로 호출하는지.** HTTP context provider 규격에 맞춰
  요청/응답을 구현했고 서버 단독 동작은 확인했으나, 에디터에서 끝까지 돌려보지 않았다.
- **UEI 매뉴얼의 구조가 CANopen 매뉴얼과 비슷한지.** 헤딩이 없거나 스캔 PDF 면
  분할 품질이 달라진다.

`spec/paths.md`, `manuals-inbox/`, `manuals-split/`, `*.c` 는 `.gitignore` 대상이다.
**매뉴얼 원본과 예제 코드는 저장소에 올리지 않는다.**

## 라이선스

MIT. 서드파티: [kordoc](https://github.com/chrisryugj/kordoc) (MIT) ·
[llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) ·
[AnythingLLM](https://github.com/Mintplex-Labs/anything-llm) (MIT) ·
Qwen2.5-Coder (Apache-2.0) · BGE-M3 (MIT)
