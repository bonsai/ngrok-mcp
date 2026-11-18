---
name: ngrok-mcp
description: ngrok 公式リモート MCP サーバー（https://mcp.ngrok.com/mcp）の台帳・登録スキル。opencode の mcp に remote として登録済み。認証は OAuth（初回にブラウザ同意。OAuth はフル権限＝アカウントのロール権限で動く、読み取り専用ではない）。agent authtoken / PAT は使わない。起動ワード「ngrok mcp」「ngrok MCP を使う」「トンネル一覧」「ngrok の状態」「ngrok-mcp」などで発動。
---

# ngrok-mcp

ngrok 公式のリモート MCP サーバー。OAuth ログインした ngrok アカウント
（bonsai / Free プラン）のリソースを MCP クライアントから操作できる。

- エンドポイント: `https://mcp.ngrok.com/mcp`（streamable HTTP）
- 認証: **OAuth**（初回はブラウザ同意）。2026-11-12 に接続済み。
  - ⚠ OAuth は**フル権限**で動く（ngrok 公式: "Access isn't read-only"）。実測でもツール
    カタログに gw_create/update/delete 系・platform_invite_team_member など書き込み系が含まれる。
    変更・削除系のツールは呼ぶ前にユーザー確認を取ること。読み取り専用に絞りたい場合は
    read スコープのみの PAT（Bearer ヘッダー）に載せ替える。
  - agent authtoken（`ngrok.yml` のもの）・API Key は MCP には使えない
  - PAT（`ngrok_pat_…`、https://dashboard.ngrok.com/access-tokens/new）は OAuth 非対応クライアント向けの代替
  - 実測メモ: 初回 OAuth で `invalid_target`（AS が opencode アプリを拒否）→ 再試行で解消。
    opencode v2.2.7 の CIMD 実装と要求内容は仕様どおりだった。再発したらまず再試行、次に PAT。
- 台帳: 本フォルダ `server.json`（URL・認証・関連リソース）
- opencode 登録: `~/.config/opencode/opencode.jsonc` → `mcp.ngrok`
  - opencode は設定を起動時に一度だけ読む。変更後は **quit → 再起動**。
  - OAuth 未完了のまま使うと 401 になる → 再起動後に ngrok ツールを1回呼び、
    表示された URL でブラウザ同意する。

## 使いどころ

- トンネル / エンドポイントの確認・管理（ローカルの `127.0.0.1:4040` 管理画面の代わり）
- 現在の常設トンネル: `<reserved-domain>.ngrok-free.dev`
  → `http://localhost:8765`（muse-bridge の `/ctl` `/ext`）
- CLI 側の操作（`ngrok http 8765` 等）は `ngrok` コマンド（scoop / 3.39.13）を使う。
  MCP はアカウント側の状態確認・管理向け、という住み分け。
- 認証・状態の CLI 確認: 本フォルダの `ngrok-auth.ps1`
  - `check` — authtoken を使い捨てトンネル起動で実検証（dashboard 不要。token 値は表示しない）
  - `doctor` — version / config / named tunnels / agent 稼働状態
  - `login-help` — dashboard が本当に必要な作業の一覧と、ブラウザログインが壊れた時のチェックリスト

## 関連 / Related

- muse-bridge: `WORKSPACE/mcp/muse-bridge/`（8765 の WS リレー本体）
- muse-crx: `WORKSPACE/crx/muse-crx/`（拡張側。承認ポップアップが唯一の実行ゲート）
- agent authtoken 設定済み: `%LOCALAPPDATA%\ngrok\ngrok.yml`（`ngrok config check` で確認）
