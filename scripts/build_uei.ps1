<#
.SYNOPSIS
  매뉴얼 PDF → 분할 → 임베딩까지 한 번에

.DESCRIPTION
  manuals-inbox\ 의 문서를 전부 처리한다.
    1) split_manual.py 로 구조 인식 분할
    2) 분할 품질 자동 점검 (섹션 수 / 중앙 길이) — 이상하면 경고
    3) ingest_split.py 로 AnythingLLM 워크스페이스에 투입 (이미 올린 건 건너뜀)

  임베더(8091)가 떠 있어야 한다. 없으면 먼저 띄운다.
  같은 문서를 다시 돌려도 안전하다.

  종료 코드: 0 성공 / 1 실패

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\build_uei.ps1
#>
[CmdletBinding()]
param(
  [string]$Workspace = "",
  [int]$MaxChars = 3000
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PathsMd  = Join-Path $RepoRoot "spec\paths.md"

function Ok([string]$m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Info([string]$m) { Write-Host "  ...    $m" }
function Warn([string]$m) { Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Die([string]$m, [string[]]$h = @()) {
  Write-Host ""; Write-Host "  [실패] $m" -ForegroundColor Red
  foreach ($x in $h) { Write-Host "         - $x" -ForegroundColor Yellow }
  Write-Host ""; exit 1
}
function Read-Key([string]$k) {
  if (-not (Test-Path $PathsMd)) { return $null }
  $l = Select-String -Path $PathsMd -Pattern "^\s*$k\s*=\s*(.+?)\s*$" | Select-Object -First 1
  if (-not $l) { return $null }
  $v = $l.Matches[0].Groups[1].Value.Trim()
  if ($v.StartsWith("<") -or $v.StartsWith("(")) { return $null }
  return $v
}
function Get-PidByPort([int]$p) {
  $rows = netstat -ano | Select-String "LISTENING" | Select-String ":$p\s"
  foreach ($r in $rows) {
    $f = ($r.ToString() -split '\s+') | Where-Object { $_ -ne '' }
    if ($f[1] -match ":$p$") { return [int]$f[-1] }
  }
  return 0
}

if (-not (Test-Path $PathsMd)) { Die "spec\paths.md 가 없다" @("setup.ps1 을 먼저 실행할 것") }
$PY  = Read-Key "PYTHON"
$BGE = Read-Key "BGE_M3_GGUF"
$LLAMA = Read-Key "LLAMA_SERVER"
if (-not $Workspace) { $Workspace = (Read-Key "UEI_WORKSPACE"); if (-not $Workspace) { $Workspace = "uei-manual" } }
if (-not $PY -or -not (Test-Path $PY)) { Die "PYTHON 경로가 잘못됐다" @("setup.ps1 재실행") }

$inbox = Join-Path $RepoRoot "manuals-inbox"
$split = Join-Path $RepoRoot "manuals-split"
if (-not (Test-Path $inbox)) { New-Item -ItemType Directory -Force $inbox | Out-Null }

$docs = @(Get-ChildItem $inbox -File | Where-Object { $_.Extension -match '^\.(pdf|hwp|hwpx|docx|xlsx|xls|hwpml)$' })
if ($docs.Count -eq 0) {
  Die "manuals-inbox\ 에 문서가 없다" @(
    "매뉴얼 PDF 를 manuals-inbox\ 에 넣고 다시 실행할 것",
    "위치: $inbox"
  )
}

Write-Host ""
Write-Host "================================================================"
Write-Host " Build UEI — 문서 $($docs.Count)건 → '$Workspace'" -ForegroundColor Cyan
Write-Host "================================================================"

# ── 1) 분할 ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[1/3] 구조 인식 분할" -ForegroundColor Cyan
$env:PYTHONIOENCODING = "utf-8"
& $PY (Join-Path $RepoRoot "scripts\split_manual.py") --input $inbox --out-dir $split --max-chars $MaxChars
if ($LASTEXITCODE -ne 0) { Die "분할 실패" @("위 오류 메시지 확인") }

# ── 2) 품질 점검 ────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[2/3] 분할 품질 점검" -ForegroundColor Cyan
$suspect = 0
foreach ($idx in (Get-ChildItem $split -Recurse -Filter "_index.json" -ErrorAction SilentlyContinue)) {
  $j = Get-Content $idx.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $n = $j.sections.Count
  if ($n -eq 0) { Warn "$($j.source): 섹션 0개"; $suspect++; continue }
  $sizes = ($j.sections.chars | Sort-Object)
  $med = $sizes[[int]($sizes.Count / 2)]
  $line = "$($j.source): 섹션 $n / 중앙 $med 자"
  # 섹션이 너무 적거나 중앙 길이가 상한에 붙으면 헤딩이 안 잡힌 것이다.
  if ($n -lt 5 -or $med -ge ($MaxChars * 0.9)) {
    Warn "$line  ← 헤딩 인식이 약하다"
    $suspect++
  } else { Ok $line }
}
if ($suspect -gt 0) {
  Warn "의심 문서 $suspect 건 — 스캔 PDF(이미지)이거나 헤딩이 없는 문서일 수 있다"
  Warn "  대응: -MaxChars 1500 으로 다시 실행하거나, 원본을 OCR 한 뒤 넣는다"
}

# ── 3) 임베딩 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "[3/3] AnythingLLM 임베딩" -ForegroundColor Cyan

if ((Get-PidByPort 3001) -eq 0) {
  Die "AnythingLLM 이 꺼져 있다" @("AnythingLLM 을 실행한 뒤 다시 돌릴 것")
}
if ((Get-PidByPort 8091) -eq 0) {
  if ($LLAMA -and $BGE -and (Test-Path $LLAMA) -and (Test-Path $BGE)) {
    Info "임베더(8091)가 없다 — 기동한다"
    $logDir = Join-Path $RepoRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force $logDir | Out-Null }
    $stamp = Get-Date -Format "yyyyMMdd"
    Start-Process -FilePath $LLAMA -WindowStyle Hidden `
      -ArgumentList @("-m", $BGE, "--alias", "bge-m3", "--host", "127.0.0.1", "--port", "8091",
                      "--embedding", "-ngl", "0", "-c", "2048", "--pooling", "cls") `
      -RedirectStandardOutput (Join-Path $logDir "embed-$stamp.out.log") `
      -RedirectStandardError  (Join-Path $logDir "embed-$stamp.err.log") | Out-Null
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 180) {
      try { $h = Invoke-RestMethod "http://127.0.0.1:8091/health" -TimeoutSec 3; if ($h.status -eq "ok") { break } } catch { }
      Start-Sleep -Seconds 1
    }
    if ((Get-PidByPort 8091) -eq 0) { Die "임베더 기동 실패" @("logs\embed-*.err.log 확인") }
    Ok "임베더 기동"
  } else {
    Die "임베더(8091)가 없고 BGE_M3_GGUF 도 확인되지 않는다" @("local-rag 의 Start-LocalRAG.bat 로 먼저 띄울 것")
  }
}

& $PY (Join-Path $RepoRoot "scripts\ingest_split.py") --dir $split --workspace $Workspace --create
$rc = $LASTEXITCODE

Write-Host ""
Write-Host "================================================================"
if ($rc -eq 0) {
  Write-Host " BUILD COMPLETE" -ForegroundColor Green
  Write-Host ""
  Write-Host " 다음: Start-UEI-Mode.bat 를 실행하고 VSCode 에서 @uei 를 쓴다"
} else {
  Write-Host " BUILD 실패 (코드 $rc)" -ForegroundColor Red
  Write-Host " 위 출력을 확인할 것. '+0 벡터' 면 임베더 문제다."
}
Write-Host "================================================================"
Write-Host ""
exit $rc
