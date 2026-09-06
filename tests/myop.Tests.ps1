# myop.psm1 のテストスイート（Pester 6 系）
#
# 実行方法:
#   Invoke-Pester -Path .\tests
#
# 安全性について:
#   このテストは $env:MYOP_VAULT_PATH を TestDrive 配下に向けることで、
#   実ユーザーのコンテナ（~\.my_vault.xml）に一切触れずに動作する。
#   最後の Describe で、実コンテナが変化していないことを検証している。

BeforeAll {
    # GitHub Actions の pwsh シェルは既定で $ErrorActionPreference = 'Stop' を設定する。
    # そのままだと myop 側の Write-Error が終了エラーになり、
    # 「エラーメッセージを出力すること」を検証するテストが例外で落ちてしまう。
    # ローカルと CI で同じ結果になるよう、スイート実行中は Continue に固定する。
    $script:OriginalErrorActionPreference = $global:ErrorActionPreference
    $global:ErrorActionPreference = 'Continue'

    $script:ModulePath = Join-Path (Split-Path $PSScriptRoot -Parent) 'myop.psm1'

    # 実ユーザーのコンテナを保護するため、テスト開始前の状態を記録しておく
    $script:RealVaultPath = Join-Path $HOME '.my_vault.xml'
    $script:RealVaultExistedBefore = Test-Path $script:RealVaultPath
    $script:RealVaultHashBefore =
        if ($script:RealVaultExistedBefore) {
            (Get-FileHash $script:RealVaultPath -Algorithm SHA256).Hash
        } else {
            $null
        }

    # コンテナの保存先をテスト用の一時パスへ差し替える
    $script:OriginalVaultPathEnv = $env:MYOP_VAULT_PATH
    $script:TestVaultPath = Join-Path $TestDrive 'vault.xml'
    $env:MYOP_VAULT_PATH = $script:TestVaultPath

    Import-Module $script:ModulePath -Force -DisableNameChecking

    # --- テスト用ヘルパー ---

    # コンテナを直接組み立てる（Read-Host のモックを介さずに前提データを用意するため）
    function Set-TestVault {
        param([hashtable]$Secrets)
        $data = @{}
        foreach ($k in $Secrets.Keys) {
            $data[$k] = ConvertTo-SecureString $Secrets[$k] -AsPlainText -Force
        }
        $data | Export-CliXml -Path $script:TestVaultPath
    }

    # コンテナから平文の値を取り出す
    function Get-TestVaultValue {
        param([string]$OpPath, [string]$Path = $script:TestVaultPath)
        $data = Import-CliXml -Path $Path
        [System.Net.NetworkCredential]::new('', $data[$OpPath]).Password
    }

    function Remove-TestVault {
        if (Test-Path $script:TestVaultPath) { Remove-Item $script:TestVaultPath -Force }
    }
}

AfterAll {
    Remove-Module myop -Force -ErrorAction SilentlyContinue
    $env:MYOP_VAULT_PATH = $script:OriginalVaultPathEnv
    $global:ErrorActionPreference = $script:OriginalErrorActionPreference
}

Describe 'コンテナパスの差し替え' {
    It 'MYOP_VAULT_PATH で指定した一時パスを使っている' {
        Remove-TestVault
        Set-TestVault @{ 'op://Personal/PathCheck/credential' = 'v' }
        Test-Path $script:TestVaultPath | Should -BeTrue
    }

    It '実ユーザーのコンテナを読んでいない' {
        Remove-TestVault
        # 実コンテナには複数のシークレットが入っているが、差し替えが効いていれば空に見える
        $out = myop-list 6>&1 | Out-String
        $out | Should -Match '登録されているシークレットはありません'
    }
}

Describe 'myop-save' {
    BeforeEach { Remove-TestVault }

    It '値を保存するとコンテナに格納される' {
        Mock -ModuleName myop Read-Host { ConvertTo-SecureString 'saved-secret' -AsPlainText -Force } -ParameterFilter { $AsSecureString }

        myop-save 'op://Personal/SaveTest/credential' 6>&1 | Out-Null

        Get-TestVaultValue 'op://Personal/SaveTest/credential' | Should -Be 'saved-secret'
    }

    It '同じパスに保存すると上書きされる' {
        Set-TestVault @{ 'op://Personal/SaveTest/credential' = 'old-value' }
        Mock -ModuleName myop Read-Host { ConvertTo-SecureString 'new-value' -AsPlainText -Force } -ParameterFilter { $AsSecureString }

        myop-save 'op://Personal/SaveTest/credential' 6>&1 | Out-Null

        Get-TestVaultValue 'op://Personal/SaveTest/credential' | Should -Be 'new-value'
    }

    It '3 階層でない op:// パスはエラーになり保存されない' {
        Mock -ModuleName myop Read-Host { ConvertTo-SecureString 'x' -AsPlainText -Force } -ParameterFilter { $AsSecureString }

        { myop-save 'op://Personal/OnlyTwo' -ErrorAction Stop } | Should -Throw

        Test-Path $script:TestVaultPath | Should -BeFalse
    }

    It 'op:// で始まらないパスはエラーになる' {
        { myop-save 'Personal/Item/field' -ErrorAction Stop } | Should -Throw
    }
}

Describe 'myop-list' {
    BeforeEach { Remove-TestVault }

    It 'コンテナが空のときは専用のメッセージを出す' {
        $out = myop-list 6>&1 | Out-String
        $out | Should -Match '登録されているシークレットはありません'
    }

    It '登録済みのパスをすべて表示する' {
        Set-TestVault @{
            'op://Personal/A/credential' = 'a'
            'op://Personal/B/credential' = 'b'
        }

        $out = myop-list 6>&1 | Out-String

        $out | Should -Match 'op://Personal/A/credential'
        $out | Should -Match 'op://Personal/B/credential'
    }

    It '値そのものは表示しない' {
        Set-TestVault @{ 'op://Personal/A/credential' = 'super-secret-value' }

        $out = myop-list 6>&1 | Out-String

        $out | Should -Not -Match 'super-secret-value'
    }
}

Describe 'myop-remove' {
    BeforeEach {
        Remove-TestVault
        Set-TestVault @{
            'op://Personal/Keep/credential'   = 'keep'
            'op://Personal/Delete/credential' = 'delete'
        }
    }

    It 'y と答えると削除される' {
        Mock -ModuleName myop Read-Host { 'y' } -ParameterFilter { -not $AsSecureString }

        myop-remove 'op://Personal/Delete/credential' 6>&1 | Out-Null

        $data = Import-CliXml -Path $script:TestVaultPath
        $data.ContainsKey('op://Personal/Delete/credential') | Should -BeFalse
        $data.ContainsKey('op://Personal/Keep/credential') | Should -BeTrue
    }

    It 'n と答えると削除されない' {
        Mock -ModuleName myop Read-Host { 'n' } -ParameterFilter { -not $AsSecureString }

        myop-remove 'op://Personal/Delete/credential' 6>&1 | Out-Null

        $data = Import-CliXml -Path $script:TestVaultPath
        $data.ContainsKey('op://Personal/Delete/credential') | Should -BeTrue
    }

    It '存在しないパスを指定すると警告を出しコンテナを変更しない' {
        $before = (Get-FileHash $script:TestVaultPath -Algorithm SHA256).Hash

        $out = myop-remove 'op://Personal/NotExist/credential' 3>&1 | Out-String

        $out | Should -Match '見つかりません'
        (Get-FileHash $script:TestVaultPath -Algorithm SHA256).Hash | Should -Be $before
    }
}

Describe 'myop-check' {
    BeforeEach {
        Remove-TestVault
        Set-TestVault @{ 'op://Personal/Registered/credential' = 'ok' }
    }

    It 'すべて登録済みなら成功メッセージを出す' {
        $envFile = Join-Path $TestDrive 'check-ok.env'
        Set-Content -Path $envFile -Value @(
            'REGISTERED="op://Personal/Registered/credential"'
            'PLAIN="localhost"'
        )

        $out = myop-check $envFile 6>&1 | Out-String

        $out | Should -Match '\[OK\]'
        $out | Should -Match 'すべてのシークレットが正常に登録されています'
    }

    It '未登録の参照があれば NG と表示し成功メッセージを出さない' {
        $envFile = Join-Path $TestDrive 'check-ng.env'
        Set-Content -Path $envFile -Value @(
            'REGISTERED="op://Personal/Registered/credential"'
            'MISSING="op://Personal/Missing/credential"'
        )

        $out = myop-check $envFile 6>&1 | Out-String

        $out | Should -Match '\[NG\]'
        $out | Should -Match 'op://Personal/Missing/credential'
        $out | Should -Not -Match 'すべてのシークレットが正常に登録されています'
    }

    It '存在しない .env を指定するとエラーを出力する' {
        $missing = Join-Path $TestDrive 'no-such-file.env'

        $err = myop-check $missing 2>&1 | Out-String

        $err | Should -Match '環境変数ファイルが見つかりません'
    }
}

Describe 'myop-eg' {
    It 'op:// 参照は保持し、平文値はプレースホルダに置換する' {
        $envFile = Join-Path $TestDrive 'eg-basic.env'
        Set-Content -Path $envFile -Value @(
            '# コメント行'
            ''
            'API_KEY="op://Personal/OpenAI/credential"'
            'DB_HOST="localhost"'
        )

        myop-eg $envFile 6>&1 | Out-Null

        $result = Get-Content "$envFile.example"
        $result | Should -Contain '# コメント行'
        $result | Should -Contain 'API_KEY="op://Personal/OpenAI/credential"'
        $result | Should -Contain 'DB_HOST="your_db_host_here"'
    }

    It '生成物に平文の値が残らない' {
        $envFile = Join-Path $TestDrive 'eg-secret.env'
        Set-Content -Path $envFile -Value 'TOKEN="raw-token-value"'

        myop-eg $envFile 6>&1 | Out-Null

        (Get-Content "$envFile.example" -Raw) | Should -Not -Match 'raw-token-value'
    }

    It '存在しない .env を指定するとエラーを出力する' {
        $missing = Join-Path $TestDrive 'no-such-file.env'

        $err = myop-eg $missing 2>&1 | Out-String

        $err | Should -Match '環境変数ファイルが見つかりません'
    }
}

Describe 'myop-export / myop-import' {
    BeforeEach { Remove-TestVault }

    It '正しいパスワードでラウンドトリップできる' {
        Set-TestVault @{
            'op://Personal/RoundTrip/credential' = 'roundtrip-secret'
            'op://Personal/Second/credential'    = 'second-secret'
        }
        $exportPath = Join-Path $TestDrive 'migration-ok.xml'
        Mock -ModuleName myop Read-Host { ConvertTo-SecureString 'correct-password' -AsPlainText -Force } -ParameterFilter { $AsSecureString }

        myop-export $exportPath 6>&1 | Out-Null
        Test-Path $exportPath | Should -BeTrue

        # 移行ファイルに平文が含まれていないこと
        (Get-Content $exportPath -Raw) | Should -Not -Match 'roundtrip-secret'

        Remove-TestVault
        myop-import $exportPath 6>&1 | Out-Null

        Get-TestVaultValue 'op://Personal/RoundTrip/credential' | Should -Be 'roundtrip-secret'
        Get-TestVaultValue 'op://Personal/Second/credential' | Should -Be 'second-secret'
    }

    It '誤ったパスワードでは失敗し、既存のコンテナを破壊しない' {
        # PR #1 の再発防止: 誤パスワード時に空のコンテナで上書きされないこと
        Set-TestVault @{ 'op://Personal/Existing/credential' = 'must-survive' }
        $exportPath = Join-Path $TestDrive 'migration-badpw.xml'

        Mock -ModuleName myop Read-Host { ConvertTo-SecureString 'right-password' -AsPlainText -Force } -ParameterFilter { $AsSecureString }
        myop-export $exportPath 6>&1 | Out-Null

        $hashBefore = (Get-FileHash $script:TestVaultPath -Algorithm SHA256).Hash

        Mock -ModuleName myop Read-Host { ConvertTo-SecureString 'wrong-password' -AsPlainText -Force } -ParameterFilter { $AsSecureString }
        myop-import $exportPath 2>&1 | Out-Null

        (Get-FileHash $script:TestVaultPath -Algorithm SHA256).Hash | Should -Be $hashBefore
        Get-TestVaultValue 'op://Personal/Existing/credential' | Should -Be 'must-survive'
    }

    It 'コンテナが無い状態のエクスポートはエラーを出力しファイルを作らない' {
        Remove-TestVault
        $outPath = Join-Path $TestDrive 'never.xml'

        $err = myop-export $outPath 2>&1 | Out-String

        $err | Should -Match 'エクスポートするデータがありません'
        Test-Path $outPath | Should -BeFalse
    }

    It '存在しない移行ファイルのインポートはエラーを出力する' {
        $missing = Join-Path $TestDrive 'no-such-migration.xml'

        $err = myop-import $missing 2>&1 | Out-String

        $err | Should -Match '移行用ファイルが見つかりません'
    }

    It '移行ファイルの形式が不正ならエラーになりコンテナを変更しない' {
        Set-TestVault @{ 'op://Personal/Existing/credential' = 'must-survive' }
        $hashBefore = (Get-FileHash $script:TestVaultPath -Algorithm SHA256).Hash

        $broken = Join-Path $TestDrive 'broken-migration.xml'
        @{ NotAVault = 'garbage' } | Export-Clixml -Path $broken

        myop-import $broken 2>&1 | Out-Null

        (Get-FileHash $script:TestVaultPath -Algorithm SHA256).Hash | Should -Be $hashBefore
    }
}

Describe 'myop run' {
    BeforeEach {
        Remove-TestVault
        Set-TestVault @{ 'op://Personal/RunTest/credential' = 'injected-secret' }
    }

    It 'op:// 参照を復号して子プロセスに渡す' {
        $envFile = Join-Path $TestDrive 'run-basic.env'
        Set-Content -Path $envFile -Value @(
            'MYOP_T_SECRET="op://Personal/RunTest/credential"'
            'MYOP_T_PLAIN="plain-value"'
        )

        $out = myop run --env-file=$envFile -- pwsh -NoProfile -Command '"$env:MYOP_T_SECRET|$env:MYOP_T_PLAIN"'

        ($out | Out-String).Trim() | Should -Be 'injected-secret|plain-value'
    }

    It '未登録の op:// 参照は警告を出す' {
        $envFile = Join-Path $TestDrive 'run-missing.env'
        Set-Content -Path $envFile -Value 'MYOP_T_MISSING="op://Personal/NotRegistered/credential"'

        $out = myop run --env-file=$envFile -- pwsh -NoProfile -Command '1' 3>&1 | Out-String

        $out | Should -Match '見つかりません'
    }

    It 'サブコマンドが run 以外ならエラーを出力する' {
        $err = myop exec -- pwsh -NoProfile -Command '1' 2>&1 | Out-String

        $err | Should -Match "'run' である必要があります"
    }

    It '実行するコマンドが無ければエラーを出力する' {
        $envFile = Join-Path $TestDrive 'run-nocmd.env'
        Set-Content -Path $envFile -Value 'FOO="bar"'

        $err = myop run --env-file=$envFile 2>&1 | Out-String

        $err | Should -Match 'アプリケーションコマンド'
    }

    It '存在しない .env を指定するとエラーを出力する' {
        $missing = Join-Path $TestDrive 'no-such.env'

        $err = myop run --env-file=$missing -- pwsh -NoProfile -Command '1' 2>&1 | Out-String

        $err | Should -Match '環境変数ファイルが見つかりません'
    }

    It '子コマンドの終了コードが呼び出し元に伝わる' {
        $envFile = Join-Path $TestDrive 'run-exit.env'
        Set-Content -Path $envFile -Value 'FOO="bar"'

        myop run --env-file=$envFile -- pwsh -NoProfile -Command 'exit 42' | Out-Null

        $LASTEXITCODE | Should -Be 42
    }
}

Describe '実ユーザーのコンテナ保護' {
    # このスイート全体を通して実コンテナに触れていないことを確認する。
    # ファイル内の最後の Describe として実行される必要がある。

    It 'テスト前後で実コンテナの存在状態が変わっていない' {
        (Test-Path $script:RealVaultPath) | Should -Be $script:RealVaultExistedBefore
    }

    It 'テスト前後で実コンテナの内容が変わっていない' {
        if ($script:RealVaultExistedBefore) {
            (Get-FileHash $script:RealVaultPath -Algorithm SHA256).Hash |
                Should -Be $script:RealVaultHashBefore
        } else {
            Set-ItResult -Skipped -Because '実コンテナがもともと存在しないため比較対象が無い'
        }
    }
}
