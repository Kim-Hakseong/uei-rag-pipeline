<#
.SYNOPSIS
  uei-rag-pipeline 원클릭 구축 — local-rag 설치가 끝난 장비 전용

.DESCRIPTION
  사람이 손으로 하던 것을 전부 자동화한다.
    1) local-rag 설치 위치를 찾아 런타임·임베더·kordoc·python 경로를 상속
    2) VRAM 을 읽어 CTX_CODER 자동 산정
    3) Qwen2.5-Coder-7B GGUF 다운로드 (이어받기 + sha256 대조)
    4) AnythingLLM API 키 자동 발급
    5) spec\paths.md 생성
    6) VSCode Continue config 생성 (기존 파일은 백업)
    7) 자가검증

  같은 인자로 다시 돌려도 안전하다. 이미 된 단계는 건너뛴다.

  종료 코드: 0 성공 / 1 실패

.PARAMETER LocalRagPath
  local-rag 저장소 경로. 생략하면 흔한 위치를 자동 탐색한다.

.PARAMETER CtxCoder
  coder 컨텍스트. 생략하면 VRAM 으로 산정한다.

.PARAMETER SkipModel
  모델 다운로드를 건너뛴다(이미 받아둔 경우).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File setup.ps1
  powershell -ExecutionPolicy Bypass -File setup.ps1 -LocalRagPath C:\Projects\kdocrag-harness\Local-rag
#>
[CmdletBinding()]
param(
  [string]$LocalRagPath = "",
  [int]$CtxCoder = 0,
  [switch]$SkipModel
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$RepoRoot = $PSScriptRoot

# ── 확정 상수 (Qwen 공식 GGUF, 2026-08 실조회) ──────────────────────────
$CODER_URL  = "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
$CODER_NAME = "qwen2.5-coder-7b-instruct-q4_k_m.gguf"
$CODER_SIZE = 4683073536
$CODER_SHA  = "509287f78cb4d4cf6b3843734733b914b2c158e43e22a7f4bf5e963800894d3c"
$CODER_ALIAS = "qwen2.5-coder-7b"

$stepNo = 0
function Step([string]$t) { $script:stepNo++; Write-Host ""; Write-Host "[$stepNo/7] $t" -ForegroundColor Cyan }
function Ok([string]$m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Info([string]$m) { Write-Host "  ...    $m" }
function Warn([string]$m) { Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Die([string]$m, [string[]]$hints = @()) {
  Write-Host ""
  Write-Host "  [실패] $m" -ForegroundColor Red
  foreach ($h in $hints) { Write-Host "         - $h" -ForegroundColor Yellow }
  Write-Host ""
  exit 1
}

function Read-Key([string]$file, [string]$key) {
  if (-not (Test-Path $file)) { return $null }
  $line = Select-String -Path $file -Pattern "^\s*$key\s*=\s*(.+?)\s*$" | Select-Object -First 1
  if (-not $line) { return $null }
  $v = $line.Matches[0].Groups[1].Value.Trim()
  if ($v.StartsWith("<") -or $v.StartsWith("(")) { return $null }
  return $v
}

Write-Host ""
Write-Host "================================================================"
Write-Host " uei-rag-pipeline setup" -ForegroundColor Cyan
Write-Host " 매뉴얼 RAG + VSCode Continue 코딩 환경을 구축한다"
Write-Host "================================================================"

# ── 1. local-rag 찾기 ───────────────────────────────────────────────────
Step "local-rag 설치 위치 확인 (런타임·임베더 상속)"
$candidates = @()
if ($LocalRagPath) { $candidates += $LocalRagPath }
$candidates += @(
  (Join-Path (Split-Path $RepoRoot -Parent) "kdocrag-harness\Local-rag"),
  (Join-Path (Split-Path $RepoRoot -Parent) "local-rag"),
  "C:\Projects\kdocrag-harness\Local-rag",
  "C:\Projects\local-rag"
)
$lr = $null
foreach ($c in $candidates) {
  if ($c -and (Test-Path (Join-Path $c "spec\paths.md"))) { $lr = (Resolve-Path $c).Path; break }
}
if (-not $lr) {
  Die "local-rag 를 찾지 못했다" @(
    "local-rag 를 먼저 설치할 것: https://github.com/Kim-Hakseong/local-rag",
    "이미 있으면 경로를 직접 지정: setup.ps1 -LocalRagPath C:\경로\local-rag"
  )
}
Ok "local-rag: $lr"

$lrPaths = Join-Path $lr "spec\paths.md"
$KORDOC = Read-Key $lrPaths "KORDOC_CMD"
$LLAMA  = Read-Key $lrPaths "LLAMA_SERVER"
$BGE    = Read-Key $lrPaths "BGE_M3_GGUF"
$PY     = Read-Key $lrPaths "PYTHON"
foreach ($p in @(@{n="LLAMA_SERVER";v=$LLAMA}, @{n="PYTHON";v=$PY})) {
  if (-not $p.v -or -not (Test-Path $p.v)) {
    Die "local-rag 의 $($p.n) 이 비었거나 파일이 없다: $($p.v)" @("local-rag 의 setup.ps1 을 먼저 완료할 것")
  }
}
Ok "런타임 상속: llama-server / python / kordoc / bge-m3"

# ── 2. VRAM → CTX_CODER ────────────────────────────────────────────────
Step "VRAM 확인 (CTX_CODER 산정)"
<#
  Qwen2.5-Coder-7B Q4_K_M 모델 가중치 약 4.7 GB (ctx 와 무관한 고정값).
  KV 계수 추정 0.045 MiB/토큰 — Qwen3-4B 실측 0.115 를 구조비로 환산한 값이다.
    Coder-7B : 28층 × kv_heads 4 × head_dim 128
    Qwen3-4B : 36층 × kv_heads 8 × head_dim 128
  ctx 32768 → KV 약 1.4 GB → 모델 포함 약 6.1 GB (8GB 카드에서 가능)
  **실측이 아니다.** OOM 이면 아래 순서로 낮춘다: 32768 → 16384 → 8192
#>
$vram = 0
try {
  $smi = Join-Path $env:SystemRoot "System32\nvidia-smi.exe"
  if (Test-Path $smi) {
    $out = & $smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
    if ($out) { $vram = [int]($out.ToString().Trim()) }
  }
} catch { }

if ($CtxCoder -le 0) {
  if     ($vram -ge 11000) { $CtxCoder = 65536 }
  elseif ($vram -ge 7000)  { $CtxCoder = 32768 }
  elseif ($vram -ge 5000)  { $CtxCoder = 16384 }
  elseif ($vram -gt 0)     { $CtxCoder = 8192  }
  else                     { $CtxCoder = 8192  }
}
if ($vram -gt 0) { Ok "VRAM $vram MiB → CTX_CODER $CtxCoder" }
else { Warn "NVIDIA GPU 미검출 → CTX_CODER $CtxCoder (CPU 추론은 매우 느리다)" }

# ── 3. coder 모델 ───────────────────────────────────────────────────────
Step "Qwen2.5-Coder-7B 다운로드 (4.7GB)"
$modelDir = Join-Path $lr "models"
if (-not (Test-Path $modelDir)) { New-Item -ItemType Directory -Force $modelDir | Out-Null }
$coderPath = Join-Path $modelDir $CODER_NAME

if ($SkipModel) {
  Info "-SkipModel 지정 — 건너뛴다"
} elseif ((Test-Path $coderPath) -and ((Get-Item $coderPath).Length -eq $CODER_SIZE)) {
  Ok "이미 있음 (크기 일치)"
} else {
  Info "받는 중… 회선에 따라 수 분 걸린다"
  $curl = Join-Path $env:SystemRoot "System32\curl.exe"
  # -C - : 이어받기. 중간에 끊겨도 다시 돌리면 이어진다.
  & $curl -L --fail -C - -o $coderPath $CODER_URL
  if ($LASTEXITCODE -ne 0) {
    Die "모델 다운로드 실패 (curl exit $LASTEXITCODE)" @(
      "네트워크/프록시 확인 후 setup.ps1 을 다시 실행하면 이어받는다",
      "수동: $CODER_URL"
    )
  }
}
if (-not $SkipModel) {
  $len = (Get-Item $coderPath).Length
  if ($len -ne $CODER_SIZE) { Die "모델 크기 불일치: $len (기대 $CODER_SIZE)" @("파일을 지우고 다시 실행할 것") }
  Info "sha256 대조 중…"
  $sha = (Get-FileHash $coderPath -Algorithm SHA256).Hash.ToLower()
  if ($sha -ne $CODER_SHA) { Die "sha256 불일치" @("받은 파일이 손상됐다. 지우고 다시 실행할 것") }
  Ok "모델 검증 완료 ($([math]::Round($len/1GB,2)) GB)"
}

# ── 4. AnythingLLM API 키 ───────────────────────────────────────────────
Step "AnythingLLM API 키 발급"
$allmUrl = "http://127.0.0.1:3001"
$apiKey = Read-Key (Join-Path $RepoRoot "spec\paths.md") "ANYTHINGLLM_API_KEY"
if ($apiKey) {
  Ok "기존 키 재사용"
} else {
  try {
    $r = Invoke-RestMethod "$allmUrl/api/system/generate-api-key" -Method Post `
           -Body "{}" -ContentType "application/json" -TimeoutSec 20
    $apiKey = $r.apiKey.secret
    Ok "발급됨"
  } catch {
    Warn "발급 실패 — AnythingLLM 이 꺼져 있는 것 같다"
    Warn "나중에 켜고 다시 실행하면 채워진다. 그때까지 @uei 는 동작하지 않는다"
    $apiKey = ""
  }
}

# ── 5. spec\paths.md ────────────────────────────────────────────────────
Step "spec\paths.md 생성"
$specDir = Join-Path $RepoRoot "spec"
if (-not (Test-Path $specDir)) { New-Item -ItemType Directory -Force $specDir | Out-Null }
$lines = @(
  "# 자동 생성 — setup.ps1 ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))",
  "# 이 파일은 .gitignore 대상이다. 개인 경로·키가 저장소에 올라가지 않는다.",
  "",
  "KORDOC_CMD     = $KORDOC",
  "LLAMA_SERVER   = $LLAMA",
  "BGE_M3_GGUF    = $BGE",
  "PYTHON         = $PY",
  "",
  "CODER_GGUF     = $coderPath",
  "CODER_ALIAS    = $CODER_ALIAS",
  "CTX_CODER      = $CtxCoder",
  "NGL_CODER      = 99",
  "",
  "ANYTHINGLLM_URL     = $allmUrl",
  "ANYTHINGLLM_API_KEY = $apiKey",
  "UEI_WORKSPACE       = uei-manual",
  "",
  "# VRAM: $(if ($vram -gt 0) { "$vram MiB" } else { '미검출' })",
  "# OOM 이면 CTX_CODER 를 낮춘다: 65536 -> 32768 -> 16384 -> 8192"
)
$utf8 = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText((Join-Path $specDir "paths.md"), ($lines -join "`n") + "`n", $utf8)
Ok "spec\paths.md 작성"

# ── 6. Continue 설정 ────────────────────────────────────────────────────
Step "VSCode Continue 설정"
$contDir = Join-Path $env:USERPROFILE ".continue"
if (-not (Test-Path $contDir)) { New-Item -ItemType Directory -Force $contDir | Out-Null }
$cfgPath = Join-Path $contDir "config.yaml"

if (Test-Path $cfgPath) {
  $backup = "$cfgPath.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  Copy-Item $cfgPath $backup
  Warn "기존 config.yaml 을 백업했다: $(Split-Path $backup -Leaf)"
}
$cfg = @"
name: uei-local
version: 0.0.1
schema: v1

models:
  - name: $CODER_ALIAS
    provider: openai
    model: $CODER_ALIAS
    apiBase: http://127.0.0.1:8090/v1
    apiKey: local
    roles: [chat, edit, apply]
    defaultCompletionOptions:
      contextLength: $CtxCoder
      maxTokens: 4096

context:
  - provider: file
  - provider: codebase
  - provider: diff
  - provider: terminal
  - provider: http
    params:
      url: http://127.0.0.1:8099/retrieve
      title: uei
      description: 매뉴얼에서 근거 문단을 찾아온다
      displayTitle: UEI 매뉴얼
"@
[IO.File]::WriteAllText($cfgPath, $cfg, $utf8)
Ok "config.yaml 작성 ($cfgPath)"

# ── 7. 자가검증 ─────────────────────────────────────────────────────────
Step "자가검증"
$fail = 0
if (Test-Path $coderPath) { Ok "coder 모델" } elseif ($SkipModel) { Warn "coder 모델 (건너뜀)" } else { Warn "coder 모델 없음"; $fail++ }
if ($KORDOC -and (Test-Path $KORDOC)) { Ok "kordoc" } else { Warn "kordoc 경로 확인 필요"; $fail++ }

try {
  & $PY -c "import sys; sys.exit(0)" 2>$null
  if ($LASTEXITCODE -eq 0) { Ok "python 실행" } else { Warn "python 실행 실패"; $fail++ }
} catch { Warn "python 실행 실패"; $fail++ }

if ($apiKey) {
  try {
    $ws = Invoke-RestMethod "$allmUrl/api/workspaces" -TimeoutSec 10
    Ok "AnythingLLM 연결 (워크스페이스 $($ws.workspaces.Count)개)"
  } catch { Warn "AnythingLLM 응답 없음 — 켠 뒤 Build-UEI.bat 을 실행할 것" }
} else {
  Warn "API 키 없음 — AnythingLLM 을 켜고 setup.ps1 을 다시 실행할 것"
}

Write-Host ""
Write-Host "================================================================"
if ($fail -eq 0) {
  Write-Host " SETUP COMPLETE" -ForegroundColor Green
} else {
  Write-Host " SETUP 완료 (경고 $fail 건)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host " 다음 순서:"
Write-Host "   1. 매뉴얼 PDF 를 manuals-inbox\ 에 넣는다"
Write-Host "   2. Build-UEI.bat  (분할 + 임베딩, 한 번만)"
Write-Host "   3. Start-UEI-Mode.bat  (코딩 시작)"
Write-Host "================================================================"
Write-Host ""
exit 0
