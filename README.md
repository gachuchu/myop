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

## `.env` の書き方

| 書き方 | 解釈 |
|---|---|
| `KEY=value` | 値は `value` |
| `KEY="value"` / `KEY='value'` | 値全体が同じ種類のクォートで囲まれていれば剥がして `value` |
| `KEY="value'` | 囲まれていないのでクォートは剥がさず、値は `"value'` |
| `export KEY=value` | 行頭の `export` は無視され、キーは `KEY` |
| `KEY=a=b` | 最初の `=` で分割し、値は `a=b` |
| `KEY=value # コメント` | 空白 + `#` 以降は行内コメント。値は `value` |
| `KEY=value#tag` | `#` の直前に空白が無ければ値の一部。値は `value#tag` |
| `KEY="value # not comment"` | クォート内の `#` は値の一部 |
| `KEY=` | 空文字列 |
| `# コメント` / 空行 | 読み飛ばされる |

キー名が `[A-Za-z_][A-Za-z0-9_]*` に合わない行や、`=` を含まない行は警告を出してスキップされます。

対応していない記法:

- ダブルクォート内のエスケープシーケンス（`\n`、`\"`）の展開
- 複数行にまたがる値
- 変数展開（`KEY=${OTHER}`）

## PC の移行

コンテナは DPAPI で暗号化されているため、ファイルコピーだけでは他の PC で復号できません。移行には専用コマンドを使います。

```powershell
# 旧PC：移行用パスワードを設定してエクスポート（デフォルトはデスクトップに出力）
myop-export

# 新PC：ファイルをコピーして取り込み（同じパスワードを入力）
myop-import
```

移行ファイルは PBKDF2（SHA-256、100,000 回反復、ランダムソルト）で導出した AES-256 キーで暗号化されており、DPAPI に依存しません。取り込み後は新 PC のユーザーアカウントで自動的に再暗号化されます。**移行完了後、移行ファイルは速やかに削除してください。**

- エクスポート時はパスワードを 2 回入力します。一致しない場合は中止され、移行ファイルは作られません
- インポート時に既存のコンテナがある場合は上書き確認を求め、取り込む直前に `~\.my_vault.xml.bak` へバックアップを取ります（`N` を選べばコンテナもバックアップも作らずに中止します）
- インポートは上書きのみで、既存のコンテナとのマージはできません

## セキュリティ上の注意

- 暗号化は Windows DPAPI に依存します。**同一 PC・同一 Windows ユーザーでのみ**復号できます（マスターパスワードはなく、Windows へのログインが認証です）
- `myop run` が注入する環境変数は、コマンドの実行中だけ有効です。終了後は実行前の状態へ戻すため、呼び出し元のセッションに平文は残りません。ただし実行中は、同一セッションの他の処理からも参照できます
- 同一ユーザーとして実行される他のプログラムはコンテナを復号できます。DPAPI はマルウェア対策ではなく、ファイル持ち出し・別ユーザーからの読み取りへの対策です

## 制限事項

- `op://` パスは `op://<Vault>/<Item>/<Field>` の 3 階層固定です
- `.env` の複数行値・変数展開・エスケープシーケンスには対応していません（「`.env` の書き方」を参照）
- `myop` のサブコマンドは `run` のみです

## 開発

テストは [Pester](https://pester.dev/) 6 系で書かれています。

```powershell
Install-Module Pester -Scope CurrentUser -Force   # 初回のみ
Invoke-Pester -Path .\tests
```

テストは `$env:MYOP_VAULT_PATH` を一時ディレクトリに向けて実行されるため、実際のコンテナ（`~\.my_vault.xml`）には触れません。テスト自身が、実行の前後でコンテナが変化していないことを検証しています。

push と Pull Request のたびに GitHub Actions（`windows-latest`）で同じテストが走ります。
