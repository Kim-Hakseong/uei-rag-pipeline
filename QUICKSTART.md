# QUICKSTART

**전제: [`local-rag`](https://github.com/Kim-Hakseong/local-rag) 설치가 끝나 있을 것.**
런타임·임베더·kordoc·Python 을 그대로 물려받으므로, 새로 받는 건 코딩용 모델 하나뿐이다.

---

## 4단계

```powershell
cd C:\Projects
git clone https://github.com/Kim-Hakseong/uei-rag-pipeline
```

그 다음은 **더블클릭 세 번**이다.

| 순서 | 파일 | 하는 일 | 언제 |
|---|---|---|---|
| 1 | **`Setup.bat`** | 경로 상속 · VRAM 으로 ctx 산정 · 모델 4.7GB 다운로드 · API 키 발급 · Continue 설정 | 처음 한 번 |
| 2 | **`Build-UEI.bat`** | 매뉴얼 분할 → 임베딩 | 매뉴얼 추가할 때마다 |
| 3 | **`Start-UEI-Mode.bat`** | coder 모델로 전환 + `@uei` 서버 기동 | 코딩할 때마다 |

`Build-UEI.bat` 전에 **매뉴얼 PDF 를 `manuals-inbox\` 에 넣어둔다.** 그게 전부다.

끝나면 `Stop-UEI-Mode.bat`. 일반 문서 질의로 돌아가려면 `local-rag` 의 `Start-LocalRAG.bat`.

---

## 각 단계가 실제로 하는 일

### 1. Setup.bat

```
[1/7] local-rag 설치 위치 확인 (런타임·임베더 상속)
[2/7] VRAM 확인 (CTX_CODER 산정)
[3/7] Qwen2.5-Coder-7B 다운로드 (4.7GB)
[4/7] AnythingLLM API 키 발급
[5/7] spec\paths.md 생성
[6/7] VSCode Continue 설정
[7/7] 자가검증
```

- **경로를 손으로 적지 않는다.** `local-rag\spec\paths.md` 에서 llama-server·bge-m3·
  kordoc·python 을 읽어온다.
- **ctx 를 손으로 정하지 않는다.** VRAM 을 읽어 정한다.

  | VRAM | CTX_CODER |
  |---|---|
  | 11 GB+ | 65536 |
  | **8 GB** | **32768** |
  | 6 GB | 16384 |
  | 그 미만 / GPU 없음 | 8192 |

- 모델은 sha256 까지 대조한다. 받다 끊기면 **다시 실행하면 이어받는다.**
- 기존 `~\.continue\config.yaml` 이 있으면 **백업 후** 새로 쓴다 (`config.yaml.bak-날짜`).
- AnythingLLM 이 꺼져 있으면 API 키 단계만 건너뛴다. 켜고 다시 돌리면 채워진다.

### 2. Build-UEI.bat

```
[1/3] 구조 인식 분할
[2/3] 분할 품질 점검
[3/3] AnythingLLM 임베딩
```

- 임베더(8091)가 없으면 **알아서 띄운다.**
- 이미 올린 파일은 건너뛴다. 여러 번 돌려도 중복되지 않는다.
- **품질을 자동으로 본다.** 섹션이 5개 미만이거나 중앙 길이가 상한에 붙으면
  `헤딩 인식이 약하다` 경고를 낸다 — 스캔 PDF 이거나 헤딩이 없는 문서라는 뜻이다.
- 끝에 `전체 벡터 N → M (+K)` 가 나온다. **+0 이면 임베딩이 안 된 것**이다.

정상 예시 (공개 매뉴얼 실측):

```
OK  EN_7000_05052.pdf: 청크 584 -> 섹션 39 (길이 min 155 / 중앙 975 / max 2975)
[OK]   EN_7000_05052.pdf: 섹션 39 / 중앙 984 자
[ingest] 완료. 워크스페이스 문서 39건 / 전체 벡터 3494 → 3662 (+168)
```

### 3. Start-UEI-Mode.bat

8090 을 coder 로 바꾸고, 임베더와 `@uei` 서버(8099)를 올린다.
VRAM 8 GB 에서 일반 모델(2.4 GB)과 coder(4.7 GB)를 **동시에 못 올리므로** 전환식이다.

VSCode 에서:

```
@uei 인코더 분해능 설정 레지스터

위 근거대로 초기화 함수를 작성해줘. 스타일은 @codebase 예제를 따라줘.
```

- `.c` 예제는 RAG 에 넣지 않는다. Continue 의 `@codebase` 가 인덱싱한다.
- 매뉴얼 파일을 `@file` 로 넣지 말 것. 2 MB 면 약 52만 토큰이라 어떤 설정으로도 안 들어간다.

---

## 문제 해결

| 증상 | 조치 |
|---|---|
| Setup 이 "local-rag 를 찾지 못했다" | `Setup.bat` 대신 `powershell -File setup.ps1 -LocalRagPath C:\경로\local-rag` |
| 모델 다운로드가 끊김 | **그냥 다시 실행.** 이어받는다 |
| coder 가 안 뜸 (`/health` 무응답) | VRAM 부족. `spec\paths.md` 의 `CTX_CODER` 를 한 단계 낮춘다 (32768 → 16384 → 8192). `logs\coder-*.err.log` 확인 |
| Build 가 "헤딩 인식이 약하다" | 스캔 PDF 일 수 있다. `powershell -File scripts\build_uei.ps1 -MaxChars 1500` 으로 강제 분할하거나 원본을 OCR 한다 |
| Build 결과가 `+0 벡터` | 임베더가 죽었다. `local-rag` 의 `Start-LocalRAG.bat` 로 띄우고 다시 실행 |
| `@uei` 가 Continue 에 안 보임 | Continue 재시작. config 오류면 Continue 출력 패널에 뜬다 |
| `@uei` 가 "HTTP 403" | AnythingLLM 을 켠 뒤 `Setup.bat` 재실행 (키 재발급) |
| `@uei` 가 "검색 결과 없음" | 워크스페이스 문서 목록부터 확인한다. **검색 실패 진단의 1단계는 목록 실사다** |
| 답이 엉뚱함 | 인덱스 번호만 쓰지 말 것. `0x607B의 정의는?`(실패) → `Position Range Limit 오브젝트는?`(성공) |
| 응답이 느림 | 자동완성(FIM)을 쓰지 않는다. 8 GB 에서 채팅과 같이 돌리면 느려진다 |

---

## 이 장비에서 처음 검증되는 것

아래는 **아직 실측되지 않았다.** 안 되면 위 표대로 조치하고 결과를 알려주면 문서에 반영한다.

- **Coder-7B 가 8 GB 에서 ctx 32768 로 뜨는지** — KV 계수 0.045 MiB/토큰은
  Qwen3-4B 실측(0.115)을 구조비로 환산한 추정치다
- **Continue 가 `@uei` 를 실제로 호출하는지** — 서버 단독 동작만 확인했다
- **UEI 매뉴얼의 헤딩 구조** — 공개 CANopen 매뉴얼로만 검증했다

Setup / Build 자체는 이 저장소를 만든 장비(RTX 2050 4GB)에서 **끝까지 돌려 확인**했다.
