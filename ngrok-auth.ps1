#requires -Version 7.0
<#
.SYNOPSIS
  ngrok の認証と状態を dashboard なしで CLI から確認する。

.DESCRIPTION
  dashboard のブラウザログインが壊れていても、トンネル運用は agent authtoken だけで完結する。
  このスクリプトは「authtoken が今実際に有効か」を実トンネル起動で検証し、
  dashboard が本当に必要な作業（API Key / PAT 発行など）だけを案内する。

  ngrok-auth.ps1 check        authtoken の有効性を実トンネル起動で検証（既定）
  ngrok-auth.ps1 doctor       agent / config / named tunnels の状態一覧
  ngrok-auth.ps1 login-help   dashboard が必要な作業とログイン fix チェックリスト

.NOTES
  authtoken の値は決して表示しない（先頭6字のみ）。
#>
param(
  [Parameter(Position = 0)]
  [ValidateSet("check", "doctor", "login-help")]
  [string]$Command = "check"
)

$ErrorActionPreference = "Stop"
$ConfigPath = Join-Path $env:LOCALAPPDATA "ngrok\ngrok.yml"
$AdminApi = "http://127.0.0.1:4040/api/tunnels"

function Read-Authtoken {
  if (-not (Test-Path $ConfigPath)) { return $null }
  $raw = Get-Content $ConfigPath -Raw
  if ($raw -match '(?m)^\s*authtoken:\s*(\S+)') { return $Matches[1] }
  return $null
}

function Get-AgentTunnels {
  try { return Invoke-RestMethod -Uri $AdminApi -TimeoutSec 2 }
  catch { return $null }
}

function Test-TokenLive {
  # 使い捨てトンネル（ngrok http 1）を数秒だけ起動し、エッジ認証の成否をログから判定する。
  # ローカルポート 1 に接続先が無くても、エッジとの認証・セッション確立は検証できる。
  $tmp = [System.IO.Path]::GetTempFileName()
  $p = Start-Process -FilePath "ngrok" `
    -ArgumentList @("http", "1", "--log", "stdout", "--log-format", "logfmt") `
    -RedirectStandardOutput $tmp -PassThru -WindowStyle Hidden
  $ok = $false
  $detail = "no session within timeout"
  try {
    for ($i = 0; $i -lt 25; $i++) {
      Start-Sleep -Milliseconds 400
      $log = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
      if ($log -match 'session (re-?)?started|authenticated as|established .*tunnel session') {
        $ok = $true
        $detail = "tunnel session started"
        break
      }
      if ($log -match '(ERR_NGROK_\d+[^\r\n]*)') { $detail = $Matches[1].Trim(); break }
      if ($log -match 'msg="(authentication failed|failed to authenticate)[^"]*"') {
        $detail = "authentication failed"
        break
      }
      if ($p.HasExited) { $detail = "ngrok exited (code $($p.ExitCode))"; break }
    }
  }
  finally {
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 300
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  }
  return [pscustomobject]@{ ok = $ok; detail = $detail }
}

function Show-Check {
  $token = Read-Authtoken
  if (-not $token) {
    Write-Host "authtoken 未設定 → " -NoNewline
    Write-Host "ngrok config add-authtoken <token>" -ForegroundColor Yellow
    Write-Host "  （token は発行済みなら dashboard 不要。メール内リンク等から取得）"
    exit 1
  }
  Write-Host ("authtoken: {0}…（{1}）" -f $token.Substring(0, [Math]::Min(6, $token.Length)), $ConfigPath)

  $agent = Get-AgentTunnels
  if ($agent) {
    Write-Host "agent 稼働中（127.0.0.1:4040）→ 認証済みセッションが存在 = token 有効 ✅" -ForegroundColor Green
    foreach ($t in $agent.tunnels) {
      Write-Host ("  {0} -> {1}" -f $t.public_url, $t.config.addr)
    }
    exit 0
  }

  Write-Host "agent 未稼働 → 使い捨てトンネルでエッジ認証を検証中..."
  $r = Test-TokenLive
  if ($r.ok) {
    Write-Host "authtoken 有効 ✅（$($r.detail)）— dashboard ログインなしでトンネル運用可" -ForegroundColor Green
    exit 0
  }
  Write-Host "authtoken 検証に失敗: $($r.detail)" -ForegroundColor Red
  Write-Host "  - token が無効/失効なら再発行して: ngrok config add-authtoken <new-token>"
  Write-Host "  - ネットワーク由来なら: ngrok diagnose で切り分け"
  exit 1
}

function Show-Doctor {
  Write-Host "== ngrok doctor =="
  try { Write-Host ("version      : " + (ngrok --version 2>&1)) } catch { Write-Host "version      : ngrok コマンドが無い" }
  try { Write-Host ("config check : " + (ngrok config check 2>&1)) } catch { }
  Write-Host ("config path  : $ConfigPath (" + ((Test-Path $ConfigPath) ? "exists" : "missing") + ")")

  $token = Read-Authtoken
  Write-Host ("authtoken    : " + ($token ? $token.Substring(0, [Math]::Min(6, $token.Length)) + "…（設定済み）" : "未設定"))

  if (Test-Path $ConfigPath) {
    $yml = Get-Content $ConfigPath -Raw
    Write-Host "named tunnels:"
    foreach ($m in [regex]::Matches($yml, '(?m)^\s{4}([\w-]+):\s*$')) {
      $name = $m.Groups[1].Value
      $block = $yml.Substring($m.Index)
      $block = $block.Substring(0, [Math]::Min($block.Length, 500))
      $domain = if ($block -match 'domain:\s*(\S+)') { $Matches[1] } else { "(random domain)" }
      $addr = if ($block -match 'addr:\s*(\S+)') { $Matches[1] } else { "?" }
      Write-Host ("  {0,-14} {1} -> {2}" -f $name, $domain, $addr)
    }
  }

  $agent = Get-AgentTunnels
  if ($agent) {
    Write-Host ("agent        : 稼働中、{0} 本のトンネル" -f $agent.tunnels.Count)
    foreach ($t in $agent.tunnels) { Write-Host ("  {0} -> {1}" -f $t.public_url, $t.config.addr) }
  }
  else {
    Write-Host "agent        : 未稼働（4040 に応答なし）→ ngrok start <name> で起動"
  }
}

function Show-LoginHelp {
  @"

dashboard（ブラウザ）が必要なのは下記だけ。トンネル運用には不要:
  - API Key / PAT の発行        https://dashboard.ngrok.com/api  /  .../access-tokens/new
  - reserved domains の管理     https://dashboard.ngrok.com/domains
  - アカウント設定・SSO・quota 確認

ログインできない時のチェックリスト（CLI からは直せない、ブラウザ側の問題が大半）:
  1. シークレットウィンドウで https://dashboard.ngrok.com/login を開く
     → 成功するなら通常ウィンドウの Cookie 壊れ。ngrok.com の Cookie のみ削除
  2. 拡張機能（広告ブロッカー系）を無効化して再試行
  3. エラー文言をメモする（ERR_NGROK_xxx / SSO エラー / リダイレクトループ 等で対処が変わる）
  4. メールアドレス違い（authtoken を持つアカウントと別アカウントでログインしていないか）
  5. パスワード不明ならログイン画面の reset を使う（メールが届くかでアカウント特定もできる）

OAuth（MCP 用）のメモ:
  - opencode の ngrok MCP は初回ツール呼び出し時にブラウザ同意 URL を出す
  - invalid_target が出たらまず再試行（実績あり）。ダメなら PAT を Bearer に載せ替え
"@ | Write-Host
}

switch ($Command) {
  "check" { Show-Check }
  "doctor" { Show-Doctor }
  "login-help" { Show-LoginHelp }
}
