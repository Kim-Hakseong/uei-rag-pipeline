<#
.SYNOPSIS
  UEI 모드 종료 — 8090 / 8091 / 8099 만

.DESCRIPTION
  포트 → PID → 이미지 경로 대조를 거쳐 **이 프로젝트가 띄운 것만** 종료한다.

  절대 금지:
    - `taskkill /im llama-server.exe` — 다른 프로젝트(local-rag 등) 인스턴스까지 죽는다.
    - pid 파일 신뢰 — stale pid 로 무관한 프로세스를 죽인 실측 사례가 있다.

  VSCode 와 AnythingLLM 은 건드리지 않는다. 직접 닫을 것.

.PARAMETER Force
  이미지 경로 검사에 실패해도 종료. 남용 금지.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\stop_all.ps1
#>
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PathsMd  = Join-Path $RepoRoot "spec\paths.md"
$PORTS    = @(8090, 8091, 8099)

function Read-SpecPath([string]$Key) {
  if (-not (Test-Path $PathsMd)) { return $null }
  $line = Select-String -Path $PathsMd -Pattern "^\s*$Key\s*=\s*(.+?)\s*$" | Select-Object -First 1
  if (-not $line) { return $null }
  $val = $line.Matches[0].Groups[1].Value.Trim()
  if ($val.StartsWith("<") -or $val.StartsWith("(")) { return $null }
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

$expected = @()
foreach ($k in @("LLAMA_SERVER", "PYTHON")) {
  $v = Read-SpecPath $k
  if ($v) { $expected += $v }
}
if ($expected.Count) { Write-Host "[stop] 허용 이미지: $($expected -join ' | ')" }
else { Write-Host "[stop] spec\paths.md 미기입 — 이미지 검사를 건너뛴다" -ForegroundColor Yellow }

$stopped = 0
foreach ($port in $PORTS) {
  $procId = Get-PidByPort $port
  if ($procId -eq 0) { Write-Host "[stop] 포트 $port : 사용 안 함"; continue }

  $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue
  if (-not $proc) { Write-Host "[stop] 포트 $port : PID $procId 조회 실패" -ForegroundColor Yellow; continue }

  Write-Host "[stop] 포트 $port -> PID $procId ($($proc.Name))"
  if ($expected.Count -and ($expected -notcontains $proc.ExecutablePath)) {
    if (-not $Force) {
      Write-Host "       !! 이미지 경로가 예상과 다르다: $($proc.ExecutablePath)" -ForegroundColor Red
      Write-Host "       종료하지 않는다 (-Force 로만 강제)" -ForegroundColor Red
      continue
    }
    Write-Host "       !! 경로 불일치이나 -Force 지정됨" -ForegroundColor Yellow
  }
  try {
    Stop-Process -Id $procId -Force -ErrorAction Stop
    Write-Host "       종료됨" -ForegroundColor Green
    $stopped++
  } catch {
    Write-Host "       종료 실패: $($_.Exception.Message)" -ForegroundColor Red
  }
}

Start-Sleep -Seconds 2
foreach ($port in $PORTS) {
  if ((Get-PidByPort $port) -eq 0) { Write-Host "[stop] 확인: 포트 $port 해제됨" }
  else { Write-Host "[stop] 확인: 포트 $port 여전히 점유 중" -ForegroundColor Red }
}
Write-Host "[stop] 종료한 프로세스 수: $stopped"
Write-Host "[stop] VSCode 와 AnythingLLM 은 그대로 두었다."
