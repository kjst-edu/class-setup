# class-setup setup.ps1 — interactive installer for Windows.
# 各ステップで Y/N を聞きながら、授業用ツールと設定を入れる。
# 副作用なしの状態確認は check.ps1 を使う。
#
# 動作モデル: 起動は Windows PowerShell 5.1 (README の powershell -c 経由)、
#   書込先はすべて pwsh 7 のもの (profile / VS Code default terminal) にハードコード。
#   学生に pwsh 7 を日常使いさせるため (5.1 は UTF-8 パイプで文字化け)。

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# --- 状態 ---
$script:RequiredSkipped  = New-Object System.Collections.ArrayList
$script:OptionalSkipped  = New-Object System.Collections.ArrayList
$script:UacWarningShown  = $false
$script:Total            = 9
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

function Invoke-Countdown {
    param([int]$Seconds = 5)
    Write-Host -NoNewline "  $Seconds 秒後に開始します..."
    while ($Seconds -gt 0) {
        Write-Host -NoNewline "  $Seconds"
        Start-Sleep -Seconds 1
        $Seconds--
    }
    Write-Host ""
    Write-Host ""
}

function Show-UacWarning {
    # 一度だけ表示。UAC を伴う最初の system-wide インストール直前に呼ぶ。
    if ($script:UacWarningShown) { return }
    Write-Host ""
    Write-Host "================================================" -ForegroundColor Yellow
    Write-Host 'これから UAC ダイアログが何度か開きます' -ForegroundColor Yellow
    Write-Host '"はい" を押してください' -ForegroundColor Yellow
    Write-Host "================================================" -ForegroundColor Yellow
    Write-Host ""
    Invoke-Countdown 5
    $script:UacWarningShown = $true
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

function Install-WingetPackage {
    # --scope user を先に試して UAC を回避。失敗時のみ system-wide にフォールバック。
    # system-wide fallback の直前に Show-UacWarning (一度だけ表示)。
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

    Show-UacWarning
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
    param([string]$Path, [string]$Begin, [string]$End, [string]$Body)
    $dir = Split-Path $Path
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $new = "$Begin`r`n$Body`r`n$End"
    if (-not (Test-Path $Path)) {
        Set-Content -Path $Path -Value $new -Encoding UTF8
        return
    }
    $content = Get-Content -Raw -Path $Path
    if ($content -match [regex]::Escape($Begin)) {
        $pattern = '(?s)' + [regex]::Escape($Begin) + '.*?' + [regex]::Escape($End)
        $content = [regex]::Replace($content, $pattern, $new)
        Set-Content -Path $Path -Value $content -Encoding UTF8 -NoNewline
    } else {
        Add-Content -Path $Path -Value "`r`n$new" -Encoding UTF8
    }
}

function Set-VSCodeDefaultTerminal {
    $userDir = Join-Path $Env:APPDATA 'Code\User'
    $settingsPath = Join-Path $userDir 'settings.json'
    $key = 'terminal.integrated.defaultProfile.windows'
    $value = 'PowerShell'   # VS Code 規約: "PowerShell" = pwsh 7

    if (-not (Test-Path $userDir)) {
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    }

    if (-not (Test-Path $settingsPath)) {
        $content = "{`r`n    `"$key`": `"$value`"`r`n}"
        Set-Content -Path $settingsPath -Value $content -Encoding UTF8
        Write-Host "  作成しました: $settingsPath" -ForegroundColor Green
        return
    }

    $raw = Get-Content -Raw -Path $settingsPath
    if ($raw -match [regex]::Escape("`"$key`"")) {
        Write-Host "  既に設定済み: $key" -ForegroundColor DarkGray
        return
    }

    # JSONC コメント除去 → parse → 追加 → 書戻し
    $stripped = $raw -replace '(?m)//[^\r\n]*', '' -replace '(?s)/\*.*?\*/', ''
    try {
        $obj = $stripped | ConvertFrom-Json
        $obj | Add-Member -NotePropertyName $key -NotePropertyValue $value -Force
        $obj | ConvertTo-Json -Depth 20 | Set-Content -Path $settingsPath -Encoding UTF8
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

# ============================================================
# [任意] 群
# ============================================================

# --- 6. GitHub Desktop ---
Show-LabelOptional "GitHub Desktop" "git CLI / VS Code Source Control パネルのみで Git 操作"
if ((Test-Path (Join-Path $Env:LOCALAPPDATA 'GitHubDesktop\GitHubDesktop.exe')) -or `
    (Test-WingetInstalled 'GitHub.GitHubDesktop')) {
    Show-AlreadyPresent
} elseif (Read-YesNo) {
    [void](Install-WingetPackage -Id 'GitHub.GitHubDesktop' -ProcessToStop 'GitHubDesktop')
} else {
    Add-OptionalSkipped 'GitHub Desktop'
}

# --- 7. PYTHONUTF8 = 1 (User) ---
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

# --- 8. プロンプトのカスタマイズ (pwsh 7 profile) ---
Show-LabelOptional "プロンプトのカスタマイズ (pwsh 7 profile に短プロンプトを1ブロック追記)" `
    "既定のプロンプトのまま"

function Get-PromptState {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 'missing' }
    $content = Get-Content -Raw $Path -ErrorAction SilentlyContinue
    if (-not $content) { return 'missing' }
    if ($content -match '# >>> class-setup prompt >>>') { return 'ours' }
    $stripped = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($stripped -match 'function\s+(global:)?prompt\b|starship init|oh-my-posh|omp init') {
        return 'existing'
    }
    return 'missing'
}

$pwsh7Profile = Join-Path $HOME 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
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
            Set-FileBlock -Path $pwsh7Profile `
                         -Begin '# >>> class-setup prompt >>>' `
                         -End   '# <<< class-setup prompt <<<' `
                         -Body  $promptBody
            Write-Host "  追記しました (新規 pwsh セッションで反映)" -ForegroundColor Green
        } else {
            Add-OptionalSkipped 'プロンプトのカスタマイズ'
        }
    }
}

# --- 9. VS Code 既定ターミナル = pwsh 7 ---
Show-LabelOptional "VS Code の既定ターミナルを pwsh 7 に" "VS Code ターミナルを毎回明示選択"
$vscodeSettings = Join-Path $Env:APPDATA 'Code\User\settings.json'
$alreadyVS = (Test-Path $vscodeSettings) -and `
             ((Get-Content -Raw $vscodeSettings) -match '"terminal\.integrated\.defaultProfile\.windows"\s*:\s*"PowerShell"')
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
