# QUICKSTART — 데스크탑에서 시작하기

**전제: [`local-rag`](https://github.com/Kim-Hakseong/local-rag) 설치가 끝나 있을 것.**
거기서 만든 llama-server · bge-m3 · kordoc · AnythingLLM · Python 을 **그대로 재사용**한다.
새로 받는 건 코딩용 모델 하나뿐이다.

---

## 1. 클론

```powershell
cd C:\Projects
git clone https://github.com/Kim-Hakseong/uei-rag-pipeline
cd uei-rag-pipeline
```

## 2. coder 모델 받기 (약 4.7 GB)

`local-rag` 의 `models\` 옆에 같이 두면 관리가 편하다.

```powershell
curl.exe -L --fail -o "C:\Projects\kdocrag-harness\Local-rag\models\qwen2.5-coder-7b-instruct-q4_k_m.gguf" ^
  "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
```

받은 뒤 크기·해시 대조 (둘 다 맞아야 한다):

```powershell
(Get-Item "...\qwen2.5-coder-7b-instruct-q4_k_m.gguf").Length      # 4683073536
(Get-FileHash "...\qwen2.5-coder-7b-instruct-q4_k_m.gguf" -Algorithm SHA256).Hash
# 509287F78CB4D4CF6B3843734733B914B2C158E43E22A7F4BF5E963800894D3C
```

> Qwen 공식 저장소 파일이다. `-00001-of-00002` 로 쪼개진 것도 있는데 **단일 파일본을 받는다.**

## 3. spec\paths.md 작성

`local-rag` 것을 복사해 와서 3줄만 더 채우면 된다.

```powershell
copy spec\paths.example.md spec\paths.md
notepad spec\paths.md
```

`local-rag\spec\paths.md` 에서 그대로 가져올 값:

| 키 | 출처 |
|---|---|
| `KORDOC_CMD` | 그대로 복사 |
| `LLAMA_SERVER` | 그대로 복사 (`runtime\llama-server.exe`) |
| `BGE_M3_GGUF` | 그대로 복사 |
| `PYTHON` | 그대로 복사 |

새로 채울 값:

```
CODER_GGUF     = C:\Projects\kdocrag-harness\Local-rag\models\qwen2.5-coder-7b-instruct-q4_k_m.gguf
CODER_ALIAS    = qwen2.5-coder-7b
CTX_CODER      = 32768
NGL_CODER      = 99
UEI_WORKSPACE  = uei-manual
ANYTHINGLLM_URL     = http://127.0.0.1:3001
ANYTHINGLLM_API_KEY = (다음 단계에서 발급)
```

**API 키 발급** — AnythingLLM 이 떠 있는 상태에서:

```powershell
curl.exe -X POST http://127.0.0.1:3001/api/system/generate-api-key
```

응답의 `secret` 값을 `ANYTHINGLLM_API_KEY` 에 넣는다.
(AnythingLLM 설정 화면 > API Keys 에서 만들어도 된다)

> `spec\paths.md` 는 `.gitignore` 대상이라 저장소에 올라가지 않는다.

## 4. 매뉴얼 분할

UEI 매뉴얼 PDF 를 `manuals-inbox\` 에 넣고:

```powershell
python scripts\split_manual.py --input manuals-inbox --dry-run     # 먼저 통계만
python scripts\split_manual.py --input manuals-inbox --out-dir manuals-split
```

**`--dry-run` 결과를 먼저 볼 것.** 기대치:

| 지표 | 정상 범위 |
|---|---|
| 섹션 수 | 문서당 수십~수백 |
| 중앙 길이 | 600~1,500자 |
| max | `--max-chars`(기본 3000) 이하 |

섹션이 몇 개뿐이거나 중앙 길이가 3,000자에 붙으면 **헤딩이 안 잡힌 것**이다.
스캔 PDF(이미지)면 텍스트가 아예 안 나온다. 그때는 아래 "문제 해결" 참조.

## 5. AnythingLLM 에 투입

**AnythingLLM 과 임베더(8091)가 떠 있어야 한다.** `local-rag` 의 `Start-LocalRAG.bat` 로 띄우면 된다.

```powershell
python scripts\ingest_split.py --dir manuals-split --workspace uei-manual --create
```

끝에 `전체 벡터 N → M (+K)` 가 나온다. **+0 이면 임베더가 죽은 것**이다.

## 6. VSCode Continue 설정

`%USERPROFILE%\.continue\config.yaml` 에 [`docs/continue-config.md`](docs/continue-config.md) 의
블록을 붙여넣는다. 핵심 3줄:

```yaml
    apiBase: http://127.0.0.1:8090/v1     # 모델
      contextLength: 32768                 # CTX_CODER 와 같은 값
      url: http://127.0.0.1:8099/retrieve  # @uei
```

## 7. 코딩

```powershell
Start-UEI-Mode.bat
```

8090 을 coder 로 바꾸고, 임베더와 `@uei` 서버까지 올린다. VSCode 에서:

```
@uei 인코더 분해능 설정 레지스터

위 근거대로 초기화 함수를 작성해줘. 스타일은 @codebase 예제를 따라줘.
```

끝나면 `Stop-UEI-Mode.bat`. **VSCode 와 AnythingLLM 은 안 닫는다.**

---

## 일반 모드로 되돌리기

VRAM 8 GB 에서 일반 모델(Qwen3-4B)과 coder(7B)를 **동시에 못 올린다**(2.4 + 4.7 GB + KV).

```powershell
Stop-UEI-Mode.bat                     # UEI 모드 종료
..\kdocrag-harness\Local-rag\Start-LocalRAG.bat   # 일반 모드
```

바탕화면에 바로가기 두 개를 만들어 두면 토글처럼 쓸 수 있다.

---

## 문제 해결

| 증상 | 원인 / 조치 |
|---|---|
| coder 기동 실패, `/health` 안 뜸 | VRAM 부족. `spec\paths.md` 의 `CTX_CODER` 를 32768 → 16384 → 8192 순으로 낮춘다. `logs\coder-*.err.log` 확인 |
| 분할 섹션이 몇 개 안 나옴 | 헤딩 인식 실패. `--max-chars 1500` 으로 낮춰 강제 분할하거나, 원본이 스캔 PDF 인지 확인 |
| 스캔 PDF 라 텍스트가 없음 | 이 파이프라인은 OCR 을 하지 않는다. Acrobat 등으로 OCR 후 투입 |
| `ingest` 가 `+0 벡터` | 임베더(8091)가 죽었다. `Start-LocalRAG.bat` 로 먼저 띄운다 |
| `@uei` 가 Continue 에 안 보임 | Continue 재시작. config 문법 오류면 Continue 출력 패널에 뜬다 |
| `@uei` 가 "HTTP 403" | `ANYTHINGLLM_API_KEY` 가 틀렸다 |
| `@uei` 가 "검색 결과 없음" | 워크스페이스에 매뉴얼이 실제로 임베딩됐는지 문서 관리 화면에서 확인. **검색 실패 진단의 1단계는 목록 실사다** |
| 답이 엉뚱함 | 인덱스 번호만 쓰지 말고 문서에 적힌 명칭을 함께 넣는다. `0x607B의 정의는?`(실패) → `Position Range Limit 오브젝트는?`(성공) |
| 응답이 매우 느림 | 자동완성(FIM) 모델을 뺀다. 8 GB 에서 채팅과 같이 쓰면 느려질 수 있다 |

---

## 이 문서가 보장하지 못하는 것

아래는 **이 장비에서 처음 검증되는 것**들이다. 안 되면 위 표대로 조치하고, 결과를 기록해 두면 좋다.

- Coder-7B 가 8 GB 에서 `ctx 32768` 로 실제로 뜨는지 — KV 계수는 추정치다
- Continue 가 `@uei` 를 실제로 호출하는지 — 서버 단독 동작만 확인했다
- UEI 매뉴얼의 헤딩 구조가 분할에 적합한지 — 공개 CANopen 매뉴얼로만 검증했다
