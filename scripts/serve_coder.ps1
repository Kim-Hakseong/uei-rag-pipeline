<#
.SYNOPSIS
  UEI 모드 기동 — Qwen2.5-Coder + 임베더 + 컨텍스트 서버

.DESCRIPTION
  목적 : VSCode Continue 로 코딩할 준비를 한 번에 끝낸다.
         1) 8090 에 이미 다른 모델(일반 모드 Qwen3-4B 등)이 떠 있으면 내린다
         2) coder 모델을 8090 에 올린다
         3) 임베더(8091)가 없으면 올린다 — 매뉴얼 검색에 필요
         4) 컨텍스트 서버(8099)를 올린다 — Continue 의 @uei

  전제 : spec\paths.md 에 LLAMA_SERVER / CODER_GGUF / BGE_M3_GGUF / PYTHON 기입.
         VRAM 8GB 에서 일반 모델과 coder 를 **동시에 못 올린다**(2.4 + 4.7GB + KV).
         그래서 전환식이다.

  주의 : 종료는 포트 기준 PID 조회로만 한다. `taskkill /im llama-server.exe` 는
         다른 프로젝트 인스턴스까지 죽이므로 절대 쓰지 않는다.

.PARAMETER CtxCoder
  coder 의 -c 값. 기본은 spec\paths.md 의 CTX_CODER, 없으면 32768.

.PARAMETER NoContextServer
  컨텍스트 서버를 띄우지 않는다 (이미 떠 있을 때).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\serve_coder.ps1
  powershell -ExecutionPolicy Bypass -File scripts\serve_coder.ps1 -CtxCoder 16384
#>
[CmdletBinding()]
param(
  [int]$CtxCoder = 0,
  [switch]$NoContextServer
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PathsMd  = Join-Path $RepoRoot "spec\paths.md"
$LogDir   = Join-Path $RepoRoot "logs"
$Stamp    = Get-Date -Format "yyyyMMdd"

$CHAT_PORT  = 8090
$EMBED_PORT = 8091
$CTX_PORT   = 8099

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Force $LogDir | Out-Null }

function Read-SpecPath([string]$Key, [string]$Default = $null) {
  if (-not (Test-Path $PathsMd)) { return $Default }
  $line = Select-String -Path $PathsMd -Pattern "^\s*$Key\s*=\s*(.+?)\s*$" | Select-Object -First 1
  if (-not $line) { return $Default }
  $val = $line.Matches[0].Groups[1].Value.Trim()
  if ($val.StartsWith("<") -or $val.StartsWith("(")) { return $Default }
  return $val
}

function Get-PidByPort([int]$Port) {
  $rows = netstat -ano | Select-String "LISTENING" | Select-String ":$Port\s"
  foreach ($r in $rows) {
    $f = ($r.ToString() -split '\s+') | Where-Object { $_ -ne '' }
    if ($f[1] -match ":$Port$") { return [int]$f[-1] }
  }
  return 0
}

function Wait-ForPort([int]$Port, [int]$TimeoutSec = 180) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    if ((Get-PidByPort $Port) -ne 0) { return $true }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

function Wait-ForHealth([int]$Port, [int]$TimeoutSec = 300) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
    try {
      $h = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/health" -TimeoutSec 5
      if ($h.status -eq "ok") { return $true }
    } catch { }   # 로딩 중 연결거부/503 은 정상이다
    Start-Sleep -Seconds 1
  }
  return $false
}

# ── 경로 ────────────────────────────────────────────────────────────────
$LLAMA = Read-SpecPath "LLAMA_SERVER"
$CODER = Read-SpecPath "CODER_GGUF"
$BGE   = Read-SpecPath "BGE_M3_GGUF"
$PY    = Read-SpecPath "PYTHON"
if ($CtxCoder -le 0) { $CtxCoder = [int](Read-SpecPath "CTX_CODER" "32768") }
$Ngl = [int](Read-SpecPath "NGL_CODER" "99")

foreach ($p in @(@{n="LLAMA_SERVER";v=$LLAMA}, @{n="CODER_GGUF";v=$CODER})) {
  if (-not $p.v) { throw "spec\paths.md 의 $($p.n) 이 비어 있다" }
  if (-not (Test-Path $p.v)) { throw "$($p.n) 경로에 파일이 없다: $($p.v)" }
}

# ── 1) 8090 에 다른 모델이 있으면 내린다 ────────────────────────────────
$existing = Get-PidByPort $CHAT_PORT
if ($existing -ne 0) {
  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$existing" -ErrorAction SilentlyContinue
  Write-Host "[uei] 8090 점유 중: PID $existing ($($proc.Name))"
  if ($proc -and $proc.ExecutablePath -eq $LLAMA) {
    Write-Host "[uei] 같은 llama-server 다 — 모델 전환을 위해 내린다"
    Stop-Process -Id $existing -Force
    Start-Sleep -Seconds 3
  } else {
    throw "8090 을 다른 프로그램이 쓰고 있다 ($($proc.ExecutablePath)). 수동 확인 필요."
  }
}

# ── 2) coder 기동 ────────────────────────────────────────────────────────
$chatArgs = @(
  "-m", $CODER,
  "--alias", (Read-SpecPath "CODER_ALIAS" "qwen2.5-coder-7b"),
  "--host", "127.0.0.1", "--port", "$CHAT_PORT",
  "-ngl", "$Ngl", "-c", "$CtxCoder",
  "--flash-attn", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"
)
Write-Host "[uei] coder 기동: -c $CtxCoder -ngl $Ngl"
Start-Process -FilePath $LLAMA -ArgumentList $chatArgs -WindowStyle Hidden `
  -RedirectStandardOutput (Join-Path $LogDir "coder-$Stamp.out.log") `
  -RedirectStandardError  (Join-Path $LogDir "coder-$Stamp.err.log") | Out-Null

if (-not (Wait-ForPort $CHAT_PORT 180)) { throw "coder 가 8090 을 열지 못했다. logs\coder-$Stamp.err.log 확인" }
if (-not (Wait-ForHealth $CHAT_PORT 300)) {
  Write-Host "[uei] /health 가 ok 가 되지 않았다. 에러 로그 마지막 20줄:" -ForegroundColor Red
  Get-Content (Join-Path $LogDir "coder-$Stamp.err.log") -Tail 20 | ForEach-Object { Write-Host "    $_" }
  throw "coder 로딩 실패 — VRAM 부족이면 CTX_CODER 를 낮출 것 (32768 -> 16384 -> 8192)"
}
Write-Host "[uei] coder OK (8090)" -ForegroundColor Green

# ── 3) 임베더 (매뉴얼 검색에 필요) ──────────────────────────────────────
if ((Get-PidByPort $EMBED_PORT) -ne 0) {
  Write-Host "[uei] 임베더 이미 실행 중 (8091)"
} elseif ($BGE -and (Test-Path $BGE)) {
  $embedArgs = @("-m", $BGE, "--alias", "bge-m3", "--host", "127.0.0.1",
                 "--port", "$EMBED_PORT", "--embedding", "-ngl", "0",
                 "-c", "2048", "--pooling", "cls")
  Write-Host "[uei] 임베더 기동 (CPU 고정)"
  Start-Process -FilePath $LLAMA -ArgumentList $embedArgs -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $LogDir "embed-$Stamp.out.log") `
    -RedirectStandardError  (Join-Path $LogDir "embed-$Stamp.err.log") | Out-Null
  if (Wait-ForHealth $EMBED_PORT 180) { Write-Host "[uei] 임베더 OK (8091)" -ForegroundColor Green }
  else { Write-Host "[uei] 임베더가 응답하지 않는다 — 매뉴얼 검색이 안 될 수 있다" -ForegroundColor Yellow }
} else {
  Write-Host "[uei] BGE_M3_GGUF 미기입 — 임베더를 건너뛴다 (매뉴얼 검색 불가)" -ForegroundColor Yellow
}

# ── 4) 컨텍스트 서버 ────────────────────────────────────────────────────
if (-not $NoContextServer) {
  if ((Get-PidByPort $CTX_PORT) -ne 0) {
    Write-Host "[uei] 컨텍스트 서버 이미 실행 중 (8099)"
  } elseif ($PY -and (Test-Path $PY)) {
    $script = Join-Path $RepoRoot "scripts\context_server.py"
    Start-Process -FilePath $PY -ArgumentList @($script) -WindowStyle Hidden `
      -RedirectStandardOutput (Join-Path $LogDir "ctx-$Stamp.out.log") `
      -RedirectStandardError  (Join-Path $LogDir "ctx-$Stamp.err.log") | Out-Null
    if (Wait-ForPort $CTX_PORT 30) { Write-Host "[uei] 컨텍스트 서버 OK (8099)" -ForegroundColor Green }
    else {
      Write-Host "[uei] 컨텍스트 서버가 뜨지 않았다. logs\ctx-$Stamp.err.log 확인" -ForegroundColor Yellow
    }
  } else {
    Write-Host "[uei] PYTHON 미기입 — 컨텍스트 서버를 건너뛴다 (@uei 불가)" -ForegroundColor Yellow
  }
}

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host " UEI 모드 준비 완료" -ForegroundColor Cyan
Write-Host "   coder  : http://127.0.0.1:8090  (ctx $CtxCoder)"
Write-Host "   embed  : http://127.0.0.1:8091"
Write-Host "   @uei   : http://127.0.0.1:8099"
Write-Host "   VSCode 에서 Continue 를 열고 @uei 로 매뉴얼을 부른다"
Write-Host "================================================" -ForegroundColor Cyan
