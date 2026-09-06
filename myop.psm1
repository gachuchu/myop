# ========================================================
# 共通設定：暗号化コンテナの保存パス
# ========================================================
# テスト時は環境変数 MYOP_VAULT_PATH でコンテナの保存先を差し替えられる
function Get-MyVaultPath {
    if ($env:MYOP_VAULT_PATH) { return $env:MYOP_VAULT_PATH }
    return "$HOME\.my_vault.xml"
}

# 内部用ヘルパー：コンテナの読み込み
function Initialize-MyVault {
    if (Test-Path (Get-MyVaultPath)) {
        return Import-CliXml -Path (Get-MyVaultPath)
    }
    return @{}
}

# ========================================================
# 内部用ヘルパー：.env ファイルの解析
# ========================================================
# myop-check / myop-eg / myop run から共通で使う。
# 1 行につき 1 つのオブジェクトを返し、Kind が行の種別を表す。
#   Entry   … KEY=VALUE として解釈できた行（Key / Value / IsOpPath が有効）
#   Comment … # で始まる行
#   Blank   … 空行
#   Invalid … = が無い、またはキー名が識別子として不正な行
#
# 意図的に対応していないもの:
#   - ダブルクォート内のエスケープシーケンス（\n、\"）の展開
#   - 複数行にまたがる値
#   - 変数展開（KEY=${OTHER}）
function ConvertFrom-MyDotEnv {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lineNumber = 0
    foreach ($rawLine in (Get-Content -Path $Path)) {
        $lineNumber++

        $entry = [ordered]@{
            LineNumber = $lineNumber
            RawLine    = $rawLine
            Kind       = 'Invalid'
            Key        = $null
            Value      = $null
            IsOpPath   = $false
        }

        if ([string]::IsNullOrWhiteSpace($rawLine)) {
            $entry.Kind = 'Blank'
            [pscustomobject]$entry
            continue
        }

        if ($rawLine -match "^\s*#") {
            $entry.Kind = 'Comment'
            [pscustomobject]$entry
            continue
        }

        # 行頭の export を取り除く
        $line = $rawLine -replace "^\s*export\s+", ''

        # 最初の = だけで分割する（値の中の = は値の一部として残す）
        $separator = $line.IndexOf('=')
        if ($separator -lt 0) {
            [pscustomobject]$entry
            continue
        }

        $key = $line.Substring(0, $separator).Trim()
        if ($key -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
            [pscustomobject]$entry
            continue
        }

        $value = ConvertFrom-MyDotEnvValue -Raw $line.Substring($separator + 1)

        $entry.Kind     = 'Entry'
        $entry.Key      = $key
        $entry.Value    = $value
        $entry.IsOpPath = $value.StartsWith('op://')
        [pscustomobject]$entry
    }
}

# 内部用ヘルパー：.env の値部分を解釈する（クォートと行内コメントの扱い）
function ConvertFrom-MyDotEnvValue {
    param([string]$Raw)

    $trimmed = $Raw.Trim()
    if ($trimmed.Length -eq 0) { return '' }

    $quote = $trimmed[0]
    if ($quote -eq '"' -or $quote -eq "'") {
        $closing = $trimmed.IndexOf($quote, 1)
        if ($closing -gt 0) {
            # 閉じクォートの後ろが空白かコメントだけなら、クォートで囲まれた値とみなす
            if ($trimmed.Substring($closing + 1) -match "^\s*(#.*)?$") {
                return $trimmed.Substring(1, $closing - 1)
            }
        }
        # 閉じていない、または後ろに別の内容が続く場合はクォートを剥がさない
    }

    # クォートで囲まれていない値は、空白 + # 以降を行内コメントとして落とす
    $comment = [regex]::Match($trimmed, "\s+#")
    if ($comment.Success) {
        return $trimmed.Substring(0, $comment.Index).TrimEnd()
    }
    return $trimmed
}

# ========================================================
# 保存・上書き (myop-save)
# ========================================================
function myop-save {
    param([Parameter(Mandatory=$true)][string]$OpPath)

    if ($OpPath -notmatch "^op://[^/]+/[^/]+/[^/]+$") {
        Write-Error "フォーマット不正。例: myop-save `"op://Personal/OpenAI/credential`""
        return
    }

    $vaultData = Initialize-MyVault
    if ($vaultData.ContainsKey($OpPath)) {
        Write-Host "既存のデータを上書きします。" -ForegroundColor Yellow
    }

    $SecureSecret = Read-Host -AsSecureString "$OpPath の値を入力してください"
    $vaultData[$OpPath] = $SecureSecret
    $vaultData | Export-CliXml -Path (Get-MyVaultPath)
    Write-Host "保存・上書きが完了しました: $OpPath" -ForegroundColor Green
}

# ========================================================
# 削除 (myop-remove)
# ========================================================
function myop-remove {
    param([Parameter(Mandatory=$true)][string]$OpPath)

    $vaultData = Initialize-MyVault
    if ($vaultData.ContainsKey($OpPath)) {
        $confirmation = Read-Host "$OpPath を本当に削除しますか？ (y/N)"
        if ($confirmation -eq 'y' -or $confirmation -eq 'Y') {
            $vaultData.Remove($OpPath)
            $vaultData | Export-CliXml -Path (Get-MyVaultPath)
            Write-Host "削除しました: $OpPath" -ForegroundColor Green
        }
    } else {
        Write-Warning "指定されたパスが見つかりません: $OpPath"
    }
}

# ========================================================
# パス一覧を表示 (myop-list)
# ========================================================
function myop-list {
    $vaultData = Initialize-MyVault
    if ($vaultData.Count -eq 0) {
        Write-Host "登録されているシークレットはありません。" -ForegroundColor Gray
        return
    }
    Write-Host "--- 登録済みシークレット一覧 ---" -ForegroundColor Cyan
    foreach ($key in $vaultData.Keys | Sort-Object) {
        Write-Host " $key"
    }
    Write-Host "--------------------------------" -ForegroundColor Cyan
}

# ========================================================
# .envファイルの整合性チェック (myop-check)
# ========================================================
function myop-check {
    param([string]$EnvFilePath = ".env")
    if (-not (Test-Path $EnvFilePath)) {
        Write-Error "環境変数ファイルが見つかりません: $EnvFilePath"
        return
    }

    $vaultData = Initialize-MyVault
    $allOk = $true
    Write-Host "[$EnvFilePath] のシークレットチェックを開始します..." -ForegroundColor Cyan

    foreach ($entry in (ConvertFrom-MyDotEnv -Path $EnvFilePath)) {
        if ($entry.Kind -eq 'Invalid') {
            Write-Warning "解析できない行をスキップしました（$($entry.LineNumber) 行目）: $($entry.RawLine)"
            continue
        }
        if ($entry.Kind -ne 'Entry' -or -not $entry.IsOpPath) { continue }

        if ($vaultData.ContainsKey($entry.Value)) {
            Write-Host "[OK] $($entry.Key) -> $($entry.Value)" -ForegroundColor Green
        } else {
            Write-Host "[NG] $($entry.Key) -> コンテナ未登録: $($entry.Value)" -ForegroundColor Red
            $allOk = $false
        }
    }
    if ($allOk) { Write-Host "すべてのシークレットが正常に登録されています！" -ForegroundColor Green }
}

# ========================================================
# .envからテンプレートを作成 (myop-eg)
# ========================================================
function myop-eg {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, Mandatory = $false)]
        [string]$EnvFilePath = ".env"
    )

    # 1. 元となるファイルの存在チェック
    if (-not (Test-Path $EnvFilePath)) {
        Write-Error "対象の環境変数ファイルが見つかりません: $EnvFilePath"
        return
    }

    # 2. 出力ファイル名の決定（一律で末尾に .example を付与するだけでOK）
    $outputPath = "${EnvFilePath}.example"

    Write-Host "[$EnvFilePath] からテンプレート [$(Split-Path $outputPath -Leaf)] を作成中..." -ForegroundColor Cyan

    $outputLines = [System.Collections.Generic.List[string]]::new()

    # 3. 1行ずつ解析して置換
    foreach ($entry in (ConvertFrom-MyDotEnv -Path $EnvFilePath)) {
        # コメント行・空行・解析できない行は原文のまま維持する
        if ($entry.Kind -ne 'Entry') {
            $outputLines.Add($entry.RawLine)
            continue
        }

        if ($entry.IsOpPath) {
            # 値が op:// のものはそのまま保持
            $outputLines.Add("$($entry.Key)=`"$($entry.Value)`"")
        } else {
            # 平文の場合は your_<環境変数名を小文字にしたもの>_here に置換
            $outputLines.Add("$($entry.Key)=`"your_$($entry.Key.ToLower())_here`"")
        }
    }

    # 4. UTF-8 (BOMなし) でファイル書き出し
    $Utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllLines($outputPath, $outputLines, $Utf8NoBom)

    Write-Host "テンプレートの生成が完了しました！ -> $outputPath" -ForegroundColor Green
}

# ========================================================
# 内部用ヘルパー：移行用パスワードから AES-256 キーを導出 (PBKDF2)
# ========================================================
function ConvertTo-MyVaultAesKey {
    param(
        [Parameter(Mandatory=$true)][securestring]$SecurePassword,
        [Parameter(Mandatory=$true)][byte[]]$Salt,
        [Parameter(Mandatory=$true)][int]$Iterations
    )
    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        return ,[System.Security.Cryptography.Rfc2898DeriveBytes]::Pbkdf2(
            $plainPassword, $Salt, $Iterations,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256, 32)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
    }
}

# ========================================================
# 内部用ヘルパー：2 つの SecureString が同じ文字列かを比較する
# ========================================================
function Test-MyVaultPasswordMatch {
    param(
        [Parameter(Mandatory=$true)][securestring]$First,
        [Parameter(Mandatory=$true)][securestring]$Second
    )
    $firstBstr  = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($First)
    $secondBstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Second)
    try {
        $firstPlain  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($firstBstr)
        $secondPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($secondBstr)
        return $firstPlain -ceq $secondPlain
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($firstBstr)
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secondBstr)
    }
}

# ========================================================
# PC移行用エクスポート (myop-export)
# ========================================================
function myop-export {
    param([string]$OutPath = "$HOME\Desktop\my_vault_migration.xml")

    if (-not (Test-Path (Get-MyVaultPath))) {
        Write-Error "エクスポートするデータがありません。"
        return
    }

    # 移行用の一時パスワードを入力（新PCでのインポート時に必要）
    Write-Host "【重要】新PCで復元するための『移行用パスワード』を設定してください。" -ForegroundColor Cyan
    $securePassword = Read-Host -AsSecureString "移行用パスワードを入力"
    if ($securePassword.Length -eq 0) {
        Write-Error "パスワードが空のため、エクスポートを中止しました。"
        return
    }

    # 打ち間違えたまま書き出すと新PCで復号できなくなるため、2回目の入力と突き合わせる
    $confirmPassword = Read-Host -AsSecureString "確認のためもう一度入力"
    if (-not (Test-MyVaultPasswordMatch -First $securePassword -Second $confirmPassword)) {
        Write-Error "パスワードが一致しません。エクスポートを中止しました。"
        return
    }

    # ランダムなソルトを生成し、パスワードからAES-256キーを導出
    $salt = [byte[]]::new(16)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($salt)
    $iterations = 100000
    [byte[]]$keyBytes = ConvertTo-MyVaultAesKey -SecurePassword $securePassword -Salt $salt -Iterations $iterations

    try {
        # 各シークレットをDPAPIではなくパスワード由来のキーで暗号化し直す
        $vaultData = Initialize-MyVault
        $encryptedData = @{}
        foreach ($opPath in $vaultData.Keys) {
            $encryptedData[$opPath] = ConvertFrom-SecureString -SecureString $vaultData[$opPath] -Key $keyBytes
        }

        @{
            Version    = 1
            Salt       = [Convert]::ToBase64String($salt)
            Iterations = $iterations
            Data       = $encryptedData
        } | Export-Clixml -Path $OutPath
    }
    finally {
        [Array]::Clear($keyBytes, 0, $keyBytes.Length)
    }

    Write-Host "`nデスクトップに移行用ファイルを書き出しました: $OutPath" -ForegroundColor Yellow
    Write-Host "※新PCにファイルをコピーし、myop-import コマンドを使って取り込んでください。" -ForegroundColor Yellow
}

# ========================================================
# PC移行用インポート (myop-import)
# ========================================================
function myop-import {
    param([string]$InPath = "$HOME\Desktop\my_vault_migration.xml")

    if (-not (Test-Path $InPath)) {
        Write-Error "移行用ファイルが見つかりません: $InPath"
        return
    }

    $payload = Import-Clixml -Path $InPath
    if (-not ($payload -is [hashtable] -and $payload['Salt'] -and $payload['Iterations'] -and $payload['Data'] -is [hashtable])) {
        Write-Error "移行用ファイルの形式が不正です。myop-export で作成したファイルを指定してください: $InPath"
        return
    }

    # エクスポート時に設定したパスワードを入力
    Write-Host "旧PCで設定した『移行用パスワード』を入力してください。" -ForegroundColor Cyan
    $securePassword = Read-Host -AsSecureString "移行用パスワードを入力"

    # ファイルに記録されたソルトと反復回数で同じキーを再導出
    $salt = [Convert]::FromBase64String($payload.Salt)
    [byte[]]$keyBytes = ConvertTo-MyVaultAesKey -SecurePassword $securePassword -Salt $salt -Iterations $payload.Iterations

    try {
        $vaultData = @{}
        foreach ($opPath in $payload.Data.Keys) {
            $vaultData[$opPath] = ConvertTo-SecureString -String $payload.Data[$opPath] -Key $keyBytes -ErrorAction Stop
        }

        # ここまで来れば復号は成功している。既存のコンテナがあれば扱いを確認する
        $vaultPath = Get-MyVaultPath
        if (Test-Path $vaultPath) {
            $confirmation = Read-Host "既存のコンテナを上書きします。よろしいですか？ (y/N)"
            if ($confirmation -ne 'y' -and $confirmation -ne 'Y') {
                Write-Host "インポートを中止しました。コンテナは変更していません。" -ForegroundColor Yellow
                return
            }

            # 書き込む直前にバックアップを取る（パスワード誤りで無駄に上書きしないため）
            $backupPath = "$vaultPath.bak"
            Copy-Item -Path $vaultPath -Destination $backupPath -Force
            Write-Host "取り込み前のコンテナをバックアップしました: $backupPath" -ForegroundColor Yellow
        }

        # 新PCのユーザーアカウント（DPAPI）で自動再暗号化して保存
        $vaultData | Export-CliXml -Path $vaultPath

        Write-Host "`n新PCへのシークレット移行が完全に成功しました！" -ForegroundColor Green
    }
    catch {
        Write-Error "復元に失敗しました。パスワードが間違っている可能性があります。 Error: $_"
    }
    finally {
        [Array]::Clear($keyBytes, 0, $keyBytes.Length)
    }
}

# ========================================================
# 実行コア (myop run) 
# ========================================================
function myop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$SubCommand,

        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$RemainingArgs
    )

    # 1. サブコマンドが 'run' かどうかを厳格にチェック
    if ($SubCommand -ne "run") {
        Write-Error "構文エラー。myop の直後は 'run' である必要があります。 例: myop run -- python main.py"
        return
    }

    # 2. 引数の解析用変数の初期化
    $envFilePath = ".env" # デフォルト値（1Password CLI準拠）
    $appCommand = @()

    # 3. 残りの引数をループで走査して解析
    # （PowerShellの仕様で '--' は関数内部に届く前に自動消去されるため、それ以外の引数をコマンドとして集めます）
    for ($i = 0; $i -lt $RemainingArgs.Count; $i++) {
        $arg = $RemainingArgs[$i]

        # 万が一、明示的にクォートされた '--' が届いた場合はスキップ
        if ($arg -eq "--") {
            continue
        }

        # '--env-file=.env'（イコール結合）のパターン
        if ($arg -like "--env-file=*") {
            $envFilePath = $arg.Substring("--env-file=".Length)
            continue
        }

        # '--env-file .env'（スペース区切り）のパターン
        if ($arg -eq "--env-file") {
            if ($i -lt $RemainingArgs.Count - 1) {
                $i++
                $envFilePath = $RemainingArgs[$i]
            } else {
                Write-Error "--env-file の後にファイル名が指定されていません。"
                return
            }
            continue
        }

        # オプション（フラグ）以外のものはすべて実行対象のアプリケーションコマンドとその引数として追加
        $appCommand += $arg
    }

    # 4. 構文バリデーション
    if ($appCommand.Count -eq 0) {
        Write-Error "構文エラー。実行するアプリケーションコマンド（-- の後ろ）が必要です。`n使い方: myop run [--env-file=.env] -- [コマンド]"
        return
    }

    if (-not (Test-Path $envFilePath)) {
        Write-Error "環境変数ファイルが見つかりません: $envFilePath"
        return
    }

    # 5. シークレットの展開と環境変数への注入
    #    コマンド終了後に呼び出し元のセッションへ平文を残さないよう、上書き前の値を控えておく
    $vaultData = Initialize-MyVault
    $originalEnv = @{}

    try {
        foreach ($entry in (ConvertFrom-MyDotEnv -Path $envFilePath)) {
            if ($entry.Kind -ne 'Entry') { continue }

            # 同じキーが複数行にある場合も、最初に見た時点の値だけを控える
            if (-not $originalEnv.ContainsKey($entry.Key)) {
                $originalEnv[$entry.Key] = [System.Environment]::GetEnvironmentVariable($entry.Key, "Process")
            }

            if ($entry.IsOpPath) {
                if ($vaultData.ContainsKey($entry.Value)) {
                    $SecureSecret = $vaultData[$entry.Value]
                    $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)
                    try {
                        $PlainSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
                        [System.Environment]::SetEnvironmentVariable($entry.Key, $PlainSecret, "Process")
                    }
                    finally {
                        # 非管理メモリ上の平文をゼロ埋めして解放する
                        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
                    }
                } else {
                    Write-Warning "暗号化コンテナ内に該当するパスが見つかりません: $($entry.Value)"
                }
            } else {
                [System.Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
            }
        }

        # 6. コマンドの実行（引数の有無に関わらずPowerShell 7で安全にアンパックして評価）
        $exe = $appCommand[0]
        $argsLeft = $appCommand | Select-Object -Skip 1
        & $exe $argsLeft
    }
    finally {
        # 7. 環境変数を実行前の状態へ戻す。
        #    元が未設定だったキーは $null を設定することで削除される。
        #    途中で止まると平文が残るため、1 つ失敗しても残りを必ず処理する。
        foreach ($key in $originalEnv.Keys) {
            try {
                [System.Environment]::SetEnvironmentVariable($key, $originalEnv[$key], "Process")
            }
            catch {
                Write-Warning "環境変数の復元に失敗しました: $key"
            }
        }
    }
}


# ========================================================
# ターミナル入力補完設定 (ArgumentCompleter)
# ========================================================

# ① myop コマンド用のインテリジェント補完
Register-ArgumentCompleter -Native -CommandName 'myop' -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    # 現在までに入力されている全引数を取得
    $tokens = $commandAst.CommandElements | ForEach-Object { $_.Value }
    $count = $tokens.Count

    # サブコマンドの補完 (myop の直後)
    if ($count -eq 1 -or ($count -eq 2 -and $wordToComplete)) {
        return @('run') | Where-Object { $_ -like "${wordToComplete}*" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }

    # 'run' 以降の補完
    if ($tokens[1] -eq 'run') {
        # セパレーター '--' が既に入力されている場合は、通常のファイル/コマンド補完に譲るため何もしない
        if ($tokens -contains '--') { return }

        # '--env-file=' で止まっている、またはファイル名を入力中の場合
        if ($wordToComplete -like '--env-file=*') {
            $prefix = '--env-file='
            $filePart = $wordToComplete.Substring($prefix.Length)
            return Get-ChildItem -Path "./${filePart}*" -File -ErrorAction SilentlyContinue | 
                Where-Object { $_.Name -like ".env*" } |
                ForEach-Object {
                    $completionText = "${prefix}$($_.Name)"
                    [System.Management.Automation.CompletionResult]::new($completionText, $_.Name, 'ProviderItem', $completionText)
                }
        }

        # フラグやセパレーターの基本候補
        $options = @('--env-file', '--')
        
        # 直前が '--env-file' だった場合は、カレントの .env 系ファイルを候補に出す
        $lastToken = $tokens[-1]
        if ($lastToken -eq '--env-file' -and -not $wordToComplete) {
            return Get-ChildItem -Path "./.env*" -File -ErrorAction SilentlyContinue | 
                ForEach-Object { [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ProviderItem', $_.Name) }
        }

        return $options | Where-Object { $_ -like "${wordToComplete}*" } | ForEach-Object { [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }
    }
}

# ② myop-save, myop-remove, myop-check, myop-eg 用のファイル・パス補完
$TargetCommands = @('myop-save', 'myop-remove', 'myop-check', 'myop-eg')
foreach ($cmd in $TargetCommands) {
    Register-ArgumentCompleter -Native -CommandName $cmd -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)

        $currentCmd = $commandAst.CommandElements[0].Value

        # myop-remove の場合は、暗号化コンテナ内の「登録済みキー(op://...)」を候補に出す
        if ($currentCmd -eq 'myop-remove') {
            $vaultData = Initialize-MyVault
            return $vaultData.Keys | 
                Where-Object { $_ -like "*${wordToComplete}*" } | 
                ForEach-Object { [System.Management.Automation.CompletionResult]::new("`"$_`"", $_, 'ParameterValue', $_) }
        }

        # それ以外のコマンド（check, eg, save）はカレントディレクトリの .env 系ファイルを候補に出す
        return Get-ChildItem -Path "./${wordToComplete}*" -File -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -like ".env*" } |
            ForEach-Object { [System.Management.Automation.CompletionResult]::new($_.Name, $_.Name, 'ProviderItem', $_.Name) }
    }
}


# ========================================================
# 外部公開設定（エクスポート）
# ========================================================
# myop、および myop- から始まる関数だけを公開し、それ以外を隠蔽します
Export-ModuleMember -Function myop, myop-*
