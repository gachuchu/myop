# myop

1Password CLI の `op run` ワークフローを、外部サービスなし・Windows 標準の暗号化機構（DPAPI）だけで実現するローカル完結型のシークレット管理 PowerShell モジュールです。

`.env` ファイルには `op://` 形式のプレースホルダだけを書き、実際のシークレットはローカルの暗号化コンテナに保存。実行時にプレースホルダを展開して環境変数としてアプリケーションに注入します。

```powershell
# .env にはプレースホルダだけを書く
#   OPENAI_API_KEY="op://Personal/OpenAI/credential"

myop run -- python main.py   # 実行時に本物の値が環境変数として注入される
```

## 特徴

- **シークレットを平文で置かない** — `.env` に書くのは参照パスのみ。誤コミットしても漏れるのはパス名だけ
- **外部サービス不要** — 保存先はローカルの `~\.my_vault.xml`。暗号化は Windows DPAPI（ログインユーザーに紐づく）
- **1Password CLI 互換の表記** — `op://Vault/Item/Field` 形式なので、将来 1Password へ移行しても `.env` はそのまま
- **単一ファイル** — 依存なしの `myop.psm1` ひとつ。タブ補完付き

## 動作要件

- Windows
- PowerShell 7 以降

## インストール

リポジトリをクローンし、PowerShell プロファイル（`$PROFILE`）に追記します。

```powershell
git clone https://github.com/gachuchu/myop.git
Add-Content $PROFILE 'Import-Module "<クローン先>\myop\myop.psm1"'
```

## 使い方

### 1. シークレットを登録する

```powershell
myop-save "op://Personal/OpenAI/credential"
# 値はマスク表示で対話入力（コマンド履歴に残らない）
```

### 2. `.env` にプレースホルダを書く

```dotenv
OPENAI_API_KEY="op://Personal/OpenAI/credential"
DB_HOST="localhost"
```

`op://` で始まる値だけが展開対象になります。平文の値はそのまま使われます。

### 3. 整合性を確認して実行する

```powershell
myop-check                  # .env 内の op:// 参照がすべて登録済みか検証
myop run -- python main.py  # 展開して実行
```

`--env-file` で別のファイルも指定できます。

```powershell
myop run --env-file=.env.production -- node server.js
```

## コマンド一覧

| コマンド | 説明 |
|---|---|
| `myop run [--env-file=.env] -- <cmd>` | `.env` を展開して環境変数を注入し、コマンドを実行 |
| `myop-save "op://..."` | シークレットを対話入力で保存・上書き |
| `myop-remove "op://..."` | シークレットを削除（確認あり・登録キーのタブ補完あり） |
| `myop-list` | 登録済みパスの一覧表示（値は表示しない） |
| `myop-check [.env]` | `.env` 内の `op://` 参照がすべて登録済みか検証 |
| `myop-eg [.env]` | `.env` から `.env.example` を生成（平文値は `your_xxx_here` に置換） |
| `myop-export [出力先]` | PC 移行用ファイルをパスワード付きでエクスポート |
| `myop-import [入力元]` | 移行用ファイルを取り込み、新 PC 用に再暗号化 |

## PC の移行

コンテナは DPAPI で暗号化されているため、ファイルコピーだけでは他の PC で復号できません。移行には専用コマンドを使います。

```powershell
# 旧PC：移行用パスワードを設定してエクスポート（デフォルトはデスクトップに出力）
myop-export

# 新PC：ファイルをコピーして取り込み（同じパスワードを入力）
myop-import
```

移行ファイルは PBKDF2（SHA-256、100,000 回反復、ランダムソルト）で導出した AES-256 キーで暗号化されており、DPAPI に依存しません。取り込み後は新 PC のユーザーアカウントで自動的に再暗号化されます。**移行完了後、移行ファイルは速やかに削除してください。**

## セキュリティ上の注意

- 暗号化は Windows DPAPI に依存します。**同一 PC・同一 Windows ユーザーでのみ**復号できます（マスターパスワードはなく、Windows へのログインが認証です）
- `myop run` は環境変数を現在のプロセスにセットするため、コマンド終了後も**その PowerShell セッション内には平文のシークレットが環境変数として残ります**。機密性の高い作業後はセッションを閉じてください
- 同一ユーザーとして実行される他のプログラムはコンテナを復号できます。DPAPI はマルウェア対策ではなく、ファイル持ち出し・別ユーザーからの読み取りへの対策です

## 制限事項

- `.env` パーサーは `KEY=VALUE` 形式の簡易実装です。行内コメントや複数行値には対応していません
- `op://` パスは `op://<Vault>/<Item>/<Field>` の 3 階層固定です
