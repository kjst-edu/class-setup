# class-setup setup.ps1 — interactive installer for Windows.
# 各ステップで Y/N を聞きながら、授業用ツールと設定を入れる。
# 副作用なしの状態確認は check.ps1 を使う。
#
# 動作モデル: 起動は Windows PowerShell 5.1 (README の powershell -c 経由)、
#   書込先はすべて pwsh 7 のもの (profile / VS Code default terminal) にハードコード。
#   学生に pwsh 7 を日常使いさせるため (5.1 は UTF-8 パイプで文字化け)。

# BOM 無し UTF-8。[Encoding]::UTF8 は BOM 付きを返すので使わない。
$script:Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $script:Utf8NoBom

# --- 状態 ---
$script:RequiredSkipped  = New-Object System.Collections.ArrayList
$script:OptionalSkipped  = New-Object System.Collections.ArrayList
$script:Total            = 10
$script:Current          = 0
$script:WingetCache      = $null

# --- ヘルパ ---

function Test-CommandPresent {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-WingetIds {
    if ($null -ne $script:WingetCache) { return $script:WingetCache }
    $ids = @{}
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        & winget export --output $tmp --disable-interactivity --accept-source-agreements 2>&1 | Out-Null
        if (Test-Path $tmp) {
            $data = Get-Content -Raw -Encoding UTF8 $tmp | ConvertFrom-Json
            foreach ($src in @($data.Sources)) {
                foreach ($pkg in @($src.Packages)) {
                    $ids[$pkg.PackageIdentifier] = $true
                }
            }
        }
    } catch { } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    $script:WingetCache = $ids
    return $ids
}

function Test-WingetInstalled {
    param([string]$Id)
    return (Get-WingetIds).ContainsKey($Id)
}

function Read-YesNo {
    Write-Host 'インストールしますか？  y + Enter = 実行 / Enter のみ = スキップ'
    Write-Host -NoNewline '> '
    $ans = Read-Host
    return $ans -match '^[yY]$'
}

function Show-LabelRequired {
    param([string]$Name)
    $script:Current++
    Write-Host ""
    Write-Host -NoNewline ("[$($script:Current)/$($script:Total)] $Name  ")
    Write-Host "[必須]" -ForegroundColor Cyan
}

function Show-LabelOptional {
    param([string]$Name, [string]$Consequence)
    $script:Current++
    Write-Host ""
    Write-Host -NoNewline ("[$($script:Current)/$($script:Total)] $Name  ")
    Write-Host "[任意]" -ForegroundColor Yellow
    Write-Host "  スキップ時: $Consequence" -ForegroundColor DarkGray
}

function Show-AlreadyPresent {
    Write-Host "  インストール済み — skip" -ForegroundColor DarkGray
}

function Add-RequiredSkipped {
    param([string]$Name)
    [void]$script:RequiredSkipped.Add($Name)
    Write-Host "  スキップしました" -ForegroundColor DarkGray
}

function Add-OptionalSkipped {
    param([string]$Name)
    [void]$script:OptionalSkipped.Add($Name)
    Write-Host "  スキップしました" -ForegroundColor DarkGray
}

function Remove-Bom {
    # UTF-8 BOM (EF BB BF) が付いていれば除去。なければ何もしない。
    param([string]$Path)
    if (-not (Test-Path $Path)) { return }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $head = New-Object byte[] 3
            $n = $fs.Read($head, 0, 3)
            if (-not ($n -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)) { return }
        } finally { $fs.Dispose() }
    } catch { return }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stripped = New-Object byte[] ($bytes.Length - 3)
    [Array]::Copy($bytes, 3, $stripped, 0, $stripped.Length)
    [System.IO.File]::WriteAllBytes($Path, $stripped)
}

function Remove-StalePromptBlocks {
    # 旧 setup.ps1 が $HOME\Documents\... や OneDrive パスに書いた prompt block を除去する。
    # 正しいパス ($pwsh7Profile) と異なる場所にある our block を自動削除。
    param([string]$CorrectPath)
    $profileRel = 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
    $blockBegin = '# >>> class-setup prompt >>>'
    $blockEnd   = '# <<< class-setup prompt <<<'
    $blockPattern = '(?s)(\r?\n)?' + [regex]::Escape($blockBegin) + '.*?' + [regex]::Escape($blockEnd) + '(\r?\n)?'

    # 候補: $HOME 直書き + OneDrive 各変数
    $candidates = @(Join-Path $HOME $profileRel)
    foreach ($name in 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') {
        $base = [Environment]::GetEnvironmentVariable($name)
        if ($base) { $candidates += Join-Path $base $profileRel }
    }
    $candidates = $candidates | Select-Object -Unique |
        Where-Object { -not [string]::Equals($_, $CorrectPath, [StringComparison]::OrdinalIgnoreCase) } |
        Where-Object { Test-Path $_ }

    foreach ($legacy in $candidates) {
        try {
            $raw = [System.IO.File]::ReadAllText($legacy, [System.Text.Encoding]::UTF8)
        } catch { continue }
        if ($raw -notmatch [regex]::Escape($blockBegin)) { continue }
        $cleaned = [regex]::Replace($raw, $blockPattern, '')
        if ($cleaned.Trim() -eq '') {
            Remove-Item $legacy -Force -ErrorAction SilentlyContinue
        } else {
            [System.IO.File]::WriteAllText($legacy, $cleaned, $script:Utf8NoBom)
        }
        Write-Host "  旧パスの prompt block を除去: $legacy" -ForegroundColor DarkGray
    }
}

function Install-WingetPackage {
    # --scope user を先に試して UAC を回避。失敗時のみ system-wide にフォールバック。
    param(
        [string]$Id,
        [string]$ProcessToStop = $null
    )

    if ($ProcessToStop) {
        $running = Get-Process -Name $ProcessToStop -ErrorAction SilentlyContinue
        if ($running) {
            Write-Host "  $ProcessToStop を停止中..." -ForegroundColor DarkGray
            $running | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "  winget install (user scope) $Id ..." -ForegroundColor DarkGray
    & winget install --id $Id --exact --scope user `
        --accept-source-agreements --accept-package-agreements `
        --silent --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  インストール完了 (user scope)" -ForegroundColor Green
        return $true
    }

    Write-Host "  winget install (system) $Id ..." -ForegroundColor DarkGray
    & winget install --id $Id --exact `
        --accept-source-agreements --accept-package-agreements `
        --silent --disable-interactivity
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  インストール完了 (system)" -ForegroundColor Green
        return $true
    }
    Write-Warning "  winget install failed for $Id (exit $LASTEXITCODE)"
    return $false
}

function Set-FileBlock {
    # Windows PowerShell 5.1 の Set-Content/Add-Content -Encoding UTF8 は BOM を書く。
    # pwsh 7 profile を BOM 付きで書きたくないので [System.IO.File] 経由で BOM 無し固定。
    param([string]$Path, [string]$Begin, [string]$End, [string]$Body)
    $dir = Split-Path $Path
    if ($dir) { [void][System.IO.Directory]::CreateDirectory($dir) }
    $new = "$Begin`r`n$Body`r`n$End"
    if (-not (Test-Path $Path)) {
        [System.IO.File]::WriteAllText($Path, $new + "`r`n", $script:Utf8NoBom)
        return
    }
    # ReadAllText は BOM を自動判別して剥がす。読み込みは UTF-8 として扱う。
    $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    if ($content -match [regex]::Escape($Begin)) {
        $pattern = '(?s)' + [regex]::Escape($Begin) + '.*?' + [regex]::Escape($End)
        $content = [regex]::Replace($content, $pattern, $new)
        [System.IO.File]::WriteAllText($Path, $content, $script:Utf8NoBom)
    } else {
        $sep = if ($content.Length -eq 0 -or $content.EndsWith("`n")) { '' } else { "`r`n" }
        [System.IO.File]::WriteAllText($Path, $content + $sep + "`r`n" + $new + "`r`n", $script:Utf8NoBom)
    }
}

function Set-VSCodeDefaultTerminal {
    $userDir = Join-Path $Env:APPDATA 'Code\User'
    $settingsPath = Join-Path $userDir 'settings.json'
    $key = 'terminal.integrated.defaultProfile.windows'
    $value = 'PowerShell'   # VS Code 規約: "PowerShell" = pwsh 7

    [void][System.IO.Directory]::CreateDirectory($userDir)

    if (-not (Test-Path $settingsPath)) {
        $content = "{`r`n    `"$key`": `"$value`"`r`n}`r`n"
        [System.IO.File]::WriteAllText($settingsPath, $content, $script:Utf8NoBom)
        Write-Host "  作成しました: $settingsPath" -ForegroundColor Green
        return
    }

    $raw = [System.IO.File]::ReadAllText($settingsPath, [System.Text.Encoding]::UTF8)
    if ($raw -match [regex]::Escape("`"$key`"")) {
        Write-Host "  既に設定済み: $key" -ForegroundColor DarkGray
        return
    }

    # ConvertFrom/To-Json は JSONC コメントを破棄してしまうので、
    # コメントがある可能性が高いファイルは触らず手動誘導する。
    # 行頭の // と /* */ のみ検出 (文字列内 URL の // への誤マッチを避ける)。
    $hasComments = ($raw -match '(?m)^\s*//') -or ($raw -match '/\*')
    if ($hasComments) {
        Write-Warning "settings.json にコメントが含まれているため、自動編集をスキップしました。"
        Write-Host "  VS Code の設定 (Ctrl+,) → 右上 '...' → 'Open Settings (JSON)' で次の行を追加してください:" -ForegroundColor Yellow
        Write-Host "    `"$key`": `"$value`"," -ForegroundColor Yellow
        return
    }

    # コメントなし: parse-rewrite ではなく、最初の '{' 直後に1行挿入してフォーマットを保つ。
    $idx = $raw.IndexOf('{')
    if ($idx -lt 0) {
        Write-Warning "settings.json に '{' が見つかりませんでした。手動で編集してください。"
        return
    }
    $before = $raw.Substring(0, $idx + 1)
    $after  = $raw.Substring($idx + 1)
    $afterTrimmed = $after.TrimStart()
    $needsComma = $afterTrimmed.Length -gt 0 -and -not $afterTrimmed.StartsWith('}')
    $sep = if ($needsComma) { ",`r`n" } else { "`r`n" }
    $insertion = "`r`n    `"$key`": `"$value`"$sep"
    $newContent = $before + $insertion + $after
    try {
        [System.IO.File]::WriteAllText($settingsPath, $newContent, $script:Utf8NoBom)
        Write-Host "  追記しました: $key = '$value'" -ForegroundColor Green
    } catch {
        Write-Warning "settings.json を自動編集できませんでした ($_)。"
        Write-Warning "VS Code の設定 (Ctrl+,) で手動で $key を '$value' にしてください。"
    }
}

# --- header ---
Write-Host ""
Write-Host "== クラスセットアップ (Windows) ==" -ForegroundColor White
Write-Host ""
Write-Host -NoNewline "[必須]" -ForegroundColor Cyan
Write-Host " = 授業で前提とするもの、欠けると困る"
Write-Host -NoNewline "[任意]" -ForegroundColor Yellow
Write-Host " = 入れた方が便利だが、帰結を理解して skip するなら自由"
Write-Host ""
Write-Host "各ステップで 'y' + Enter で実行、Enter だけでスキップ。"
Write-Host "途中で Ctrl+C を押せばいつでも中断できます。"
Write-Host ""

# ============================================================
# [必須] 群: アプリ
# ============================================================

# --- 1. PowerShell 7 ---
Show-LabelRequired "PowerShell 7"
if ((Test-CommandPresent 'pwsh') -or (Test-WingetInstalled 'Microsoft.PowerShell')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'Microsoft.PowerShell')
} else {
    Add-RequiredSkipped 'PowerShell 7'
}

# --- 2. Git for Windows ---
Show-LabelRequired "Git for Windows"
if ((Test-CommandPresent 'git') -or (Test-WingetInstalled 'Git.Git')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'Git.Git')
} else {
    Add-RequiredSkipped 'Git'
}

# --- 3. GitHub CLI ---
Show-LabelRequired "GitHub CLI (gh コマンド)"
if ((Test-CommandPresent 'gh') -or (Test-WingetInstalled 'GitHub.cli')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'GitHub.cli')
} else {
    Add-RequiredSkipped 'gh'
}

# --- 4. Visual Studio Code ---
Show-LabelRequired "Visual Studio Code"
if ((Test-CommandPresent 'code') -or (Test-WingetInstalled 'Microsoft.VisualStudioCode')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'Microsoft.VisualStudioCode')
} else {
    Add-RequiredSkipped 'Visual Studio Code'
}

# --- 5. uv ---
Show-LabelRequired "uv (Python パッケージマネージャ)"
if ((Test-CommandPresent 'uv') -or (Test-WingetInstalled 'astral-sh.uv')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'astral-sh.uv')
} else {
    Add-RequiredSkipped 'uv'
}

# --- 6. ~/.local/bin を PATH に追加 ---
Show-LabelRequired "~/.local/bin を PATH に追加 (uv tool install 先)"
$localBin = Join-Path $HOME '.local\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
# 現在のセッション PATH またはユーザー環境変数に含まれているか確認
$inCurrentPath = ($Env:Path -split ';' | Where-Object { $_ -eq $localBin }).Count -gt 0
$inUserPath    = $userPath -and ($userPath -split ';' | Where-Object { $_ -eq $localBin }).Count -gt 0
if ($inCurrentPath -or $inUserPath) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    if ($userPath) {
        [Environment]::SetEnvironmentVariable('Path', "$localBin;$userPath", 'User')
    } else {
        [Environment]::SetEnvironmentVariable('Path', $localBin, 'User')
    }
    $Env:Path = "$localBin;$Env:Path"
    Write-Host "  設定しました: $localBin をユーザー PATH に追加" -ForegroundColor Green
    Write-Host "  (新規プロセスから有効。現在のセッションにも一時反映済み)" -ForegroundColor DarkGray
} else {
    Add-RequiredSkipped '~/.local/bin PATH'
}

# ============================================================
# [任意] 群
# ============================================================

# --- 7. GitHub Desktop ---
Show-LabelOptional "GitHub Desktop" "git CLI / VS Code Source Control パネルのみで Git 操作"
if ((Test-Path (Join-Path $Env:LOCALAPPDATA 'GitHubDesktop\GitHubDesktop.exe')) -or `
    (Test-WingetInstalled 'GitHub.GitHubDesktop')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'GitHub.GitHubDesktop' -ProcessToStop 'GitHubDesktop')
} else {
    Add-OptionalSkipped 'GitHub Desktop'
}

# --- 8. PYTHONUTF8 = 1 (User) ---
Show-LabelOptional "Python の UTF-8 設定 (PYTHONUTF8=1)" `
    "Python I/O が cp932 既定 / cross-platform で文字化けリスク"
if ([Environment]::GetEnvironmentVariable('PYTHONUTF8','User') -eq '1') {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [Environment]::SetEnvironmentVariable('PYTHONUTF8', '1', 'User')
    Write-Host "  設定しました: PYTHONUTF8=1 (User)" -ForegroundColor Green
    Write-Host "  (新規プロセスから有効。現在のセッションには反映されません)" -ForegroundColor DarkGray
} else {
    Add-OptionalSkipped 'PYTHONUTF8'
}

# --- 9. プロンプトのカスタマイズ (pwsh 7 profile) ---
Show-LabelOptional "プロンプトのカスタマイズ (pwsh 7 profile に短プロンプトを1ブロック追記)" `
    "既定のプロンプトのまま"

function Get-PromptState {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 'missing' }
    try {
        $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch { return 'missing' }
    if (-not $content) { return 'missing' }
    if ($content -match '# >>> class-setup prompt >>>') { return 'ours' }
    $stripped = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($stripped -match 'function\s+(global:)?prompt\b|starship init|oh-my-posh|omp init') {
        return 'existing'
    }
    return 'missing'
}

# OneDrive がドキュメントをリダイレクトしていると $HOME\Documents は実際の場所ではない。
# GetFolderPath('MyDocuments') はリダイレクト後の実パスを返し、pwsh 7 の $PROFILE と一致する。
# 空が返るケース (OneDrive 未ログイン等) に備え $HOME\Documents をフォールバック。
$myDocs = [Environment]::GetFolderPath('MyDocuments')
if (-not $myDocs) { $myDocs = Join-Path $HOME 'Documents' }
$pwsh7Profile = Join-Path $myDocs 'PowerShell\Microsoft.PowerShell_profile.ps1'

# 旧 setup.ps1 の不具合修復: 間違ったパスに残った prompt block を除去し、BOM を剥がす。
Remove-StalePromptBlocks -CorrectPath $pwsh7Profile
Remove-Bom $pwsh7Profile

switch (Get-PromptState $pwsh7Profile) {
    'ours' {
        Show-AlreadyPresent
    }
    'existing' {
        Write-Host "  既存のプロンプト設定を検出 — 上書き回避のため skip" -ForegroundColor DarkGray
        [void]$script:OptionalSkipped.Add('プロンプトのカスタマイズ (既存検出)')
    }
    'missing' {
        if (Read-YesNo) {
            $promptBody = @'
function prompt {
    $leaf = Split-Path -Leaf $PWD.Path
    if (-not $leaf) { $leaf = $PWD.Path }
    $branch = $null
    try { $branch = git -C $PWD.Path symbolic-ref --short HEAD 2>$null } catch {}
    $tail = if ($branch) { " ($branch)" } else { '' }
    "$leaf$tail > "
}
'@
            try {
                Set-FileBlock -Path $pwsh7Profile `
                             -Begin '# >>> class-setup prompt >>>' `
                             -End   '# <<< class-setup prompt <<<' `
                             -Body  $promptBody
                Write-Host "  追記しました (新規 pwsh セッションで反映)" -ForegroundColor Green
            } catch {
                Write-Warning "プロファイルの書込みに失敗: $_"
                Write-Warning "対象パス: $pwsh7Profile"
                Write-Warning "OneDrive のセットアップ状態やドキュメントフォルダの設定を確認してください。"
                [void]$script:OptionalSkipped.Add('プロンプトのカスタマイズ (書込み失敗)')
            }
        } else {
            Add-OptionalSkipped 'プロンプトのカスタマイズ'
        }
    }
}

# --- 10. VS Code 既定ターミナル = pwsh 7 ---
Show-LabelOptional "VS Code の既定ターミナルを pwsh 7 に" "VS Code ターミナルを毎回明示選択"
$vscodeSettings = Join-Path $Env:APPDATA 'Code\User\settings.json'
Remove-Bom $vscodeSettings
$alreadyVS = (Test-Path $vscodeSettings) -and `
             ([System.IO.File]::ReadAllText($vscodeSettings, [System.Text.Encoding]::UTF8) -match '"terminal\.integrated\.defaultProfile\.windows"\s*:\s*"PowerShell"')
if ($alreadyVS) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    Set-VSCodeDefaultTerminal
} else {
    Add-OptionalSkipped 'VS Code 既定ターミナル'
}

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "== セットアップ終了 ==" -ForegroundColor White

if ($script:RequiredSkipped.Count -gt 0) {
    Write-Host ""
    Write-Host "[警告] 以下の [必須] 項目を skip しました。授業の説明と合わない可能性があります:" -ForegroundColor Red
    foreach ($n in $script:RequiredSkipped) { Write-Host "  - $n" }
}

if ($script:OptionalSkipped.Count -gt 0) {
    Write-Host ""
    Write-Host "スキップした [任意] 項目:" -ForegroundColor DarkGray
    foreach ($n in $script:OptionalSkipped) { Write-Host "  - $n" }
}

Write-Host ""
Write-Host "確認: 次のコマンドで状態を再チェックできます"
Write-Host '  powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/check.ps1 | iex"'
Write-Host ""
Write-Host "これ以降は PowerShell 7 (pwsh) を使ってください。" -ForegroundColor Cyan
Write-Host "  - スタートメニューで 'pwsh' を検索 → 起動"
Write-Host "  - VS Code のターミナル (Ctrl+\`) は自動で pwsh 7 が選ばれます"
Write-Host ""
