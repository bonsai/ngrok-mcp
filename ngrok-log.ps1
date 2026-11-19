#requires -Version 7.0
<#
.SYNOPSIS
  ngrok named tunnel をログファイル付きでバックグラウンド運用する。

.DESCRIPTION
  Windows には systemd / journald が無いので、agent を隠しプロセスで起動し
  JSON ログをファイルに落として後から追えるようにする。
  自分が起動した agent は PID 記録ベースで停止する（外部起動のものは触らない）。

  ngrok-log.ps1 up [name]      バックグラウンド起動（既定 muse-bridge）。4040 が生きていれば再利用
  ngrok-log.ps1 down [name]    自分が起動した agent を停止
  ngrok-log.ps1 tail [name]    ログ末尾を整形表示（-Count で行数、既定 30）
  ngrok-log.ps1 errs [name]    ERROR / WARN のみ抜粋（-Count で行数）
  ngrok-log.ps1 requests [name]  4040 の request capture（HTTP トンネルのリクエスト一覧）
  ngrok-log.ps1 status [name]  agent 稼働状態とトンネル一覧

  共通オプション: -Count <int>（tail/errs/requests の件数）
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet("up", "down", "tail", "errs", "requests", "status")]
  [string]$Command = "status",
  [Parameter(Position = 1)]
  [string]$Name = "muse-bridge",
  [int]$Count = 30
)

$ErrorActionPreference = "Stop"
$LogDir = Join-Path $env:LOCALAPPDATA "ngrok\logs"
$LogFile = Join-Path $LogDir "$Name.log"
$PidFile = Join-Path $LogDir "$Name.pid"
$AdminApi = "http://127.0.0.1:4040"

function Get-AgentTunnels {
  try { return Invoke-RestMethod -Uri "$AdminApi/api/tunnels" -TimeoutSec 2 }
  catch { return $null }
}

function Read-LogLines {
  param([int]$Take, [switch]$OnlyProblems)
  if (-not (Test-Path $LogFile)) {
    Write-Host "log file が無い: $LogFile（up で起動すると作られる）"
    return
  }
  $lines = Get-Content $LogFile -Tail ([Math]::Max($Take * 6, 200))
  if ($OnlyProblems) {
    $lines = @($lines | Where-Object { $_ -match '"lvl":"(err|error|warn|warning)"' -or $_ -match '(?i)error|warn' })
    $lines = @($lines | Select-Object -Last $Take)
  }
  foreach ($line in $lines) {
    $rec = $null
    try { $rec = $line | ConvertFrom-Json } catch { }
    if ($rec) {
      $lvl = $rec.lvl ?? $rec.level ?? "info"
      $msg = $rec.msg ?? $rec.message ?? ""
      $extra = @()
      if ($rec.err) { $extra += "err=$($rec.err)" }
      if ($rec.url) { $extra += "url=$($rec.url)" }
      if ($rec.addr) { $extra += "addr=$($rec.addr)" }
      if ($rec.obj) { $extra += "obj=$($rec.obj)" }
      Write-Host ("{0} [{1}] {2} {3}" -f ($rec.t ?? ""), $lvl.ToUpper(), $msg, ($extra -join " "))
    }
    else {
      # 整形できない行（起動直後のプレーン出力など）は生のまま
      Write-Host $line
    }
  }
}

switch ($Command) {
  "up" {
    $agent = Get-AgentTunnels
    if ($agent) {
      Write-Host "agent は既に稼働中（4040 応答あり）→ 再利用します"
      foreach ($t in $agent.tunnels) { Write-Host ("  {0} -> {1}" -f $t.public_url, $t.config.addr) }
      exit 0
    }
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    if (Test-Path $PidFile) { Remove-Item $PidFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $LogFile) { Remove-Item $LogFile -Force -ErrorAction SilentlyContinue }
    $p = Start-Process -FilePath "ngrok" `
      -ArgumentList @("start", $Name, "--log=$LogFile", "--log-format=json", "--log-level=info") `
      -WindowStyle Hidden -PassThru
    Set-Content -Path $PidFile -Value $p.Id
    Write-Host ("起動: ngrok start {0} (pid {1})" -f $Name, $p.Id)
    Write-Host ("log : {0}" -f $LogFile)

    # セッション確立 or エラーを待つ
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Milliseconds 400
      $agent = Get-AgentTunnels
      if ($agent -and $agent.tunnels -and $agent.tunnels.Count -gt 0) {
        foreach ($t in $agent.tunnels) { Write-Host ("tunnel: {0} -> {1} ✅" -f $t.public_url, $t.config.addr) -ForegroundColor Green }
        exit 0
      }
      if (Test-Path $LogFile) {
        $raw = Get-Content $LogFile -Raw -ErrorAction SilentlyContinue
        if ($raw -match '(ERR_NGROK_\d+[^\r\n"]*)') {
          Write-Host "起動エラー: $($Matches[1])" -ForegroundColor Red
          Write-Host "詳細: ngrok-log.ps1 tail -Count 20"
          exit 1
        }
      }
      if ($p.HasExited) { Write-Host "agent が即終了（code $($p.ExitCode)) → tail で確認" -ForegroundColor Red; exit 1 }
    }
    Write-Host "タイムアウト: セッション確立の確認が取れず（tail でログを確認）" -ForegroundColor Yellow
    exit 1
  }
  "down" {
    if (Test-Path $PidFile) {
      $pidToStop = Get-Content $PidFile
      try {
        Stop-Process -Id $pidToStop -Force -ErrorAction Stop
        Write-Host "停止: pid $pidToStop ($Name) ✅"
      }
      catch {
        Write-Host "pid $pidToStop は既に無い（おそらく手動停止済み）"
      }
      Remove-Item $PidFile -Force -ErrorAction SilentlyContinue
    }
    else {
      Write-Host "PID 記録が無い: $PidFile" 
      Write-Host "（外部起動の agent は本スクリプトからは停止しません。タスクマネージャか Stop-Process -Name ngrok で）"
    }
  }
  "tail" { Read-LogLines -Take $Count }
  "errs" { Read-LogLines -Take $Count -OnlyProblems }
  "status" {
    $agent = Get-AgentTunnels
    if ($agent) {
      Write-Host "agent: 稼働中 ✅"
      foreach ($t in $agent.tunnels) { Write-Host ("  {0} -> {1}" -f $t.public_url, $t.config.addr) }
    }
    else { Write-Host "agent: 未稼働（4040 応答なし）" }
    Write-Host ("log  : {0} ({1})" -f $LogFile, ((Test-Path $LogFile) ? "exists, $((Get-Item $LogFile).Length) bytes" : "none"))
    if (Test-Path $PidFile) { Write-Host ("pid  : {0}（本スクリプト管理）" -f (Get-Content $PidFile)) }
  }
  "requests" {
    try {
      $r = Invoke-RestMethod -Uri "$AdminApi/api/requests/http" -TimeoutSec 3
    }
    catch {
      Write-Host "request capture を取得できません（agent 未稼働 or 4040 無応答）: $($_.Exception.Message)"
      exit 1
    }
    $recs = $r.records
    if (-not $recs -or $recs.Count -eq 0) { Write-Host "キャプチャされたリクエストはまだ無い"; exit 0 }
    Write-Host ("直近 {0} 件（全 {1} 件）:" -f ([Math]::Min($Count, $recs.Count)), $recs.Count)
    foreach ($rec in ($recs | Select-Object -First $Count)) {
      $m = $rec.request.method ?? "?"
      $u = $rec.request.uri ?? "?"
      $s = $rec.response.status_code ?? "?"
      $t = $rec.t ?? ""
      Write-Host ("  {0}  {1} {2} -> {3}" -f $t, $m, $u, $s)
    }
    Write-Host "（全件は $AdminApi/http-request-detail と $AdminApi/api/requests/http）"
  }
}
