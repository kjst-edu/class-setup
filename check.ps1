# class-setup check.ps1 — diagnostic only, no side effects.
# Reports the install state of class tools, splitting required vs optional.
# Run via:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/check.ps1 | iex"

# Subprocess encoding: this script runs in a fresh `powershell -c` process,
# so setting OutputEncoding does not leak back to the user's shell.
# BOM 無し UTF-8 を使う ([Encoding]::UTF8 は BOM 付き)。
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$requiredMissing = New-Object System.Collections.ArrayList
$optionalMissing = New-Object System.Collections.ArrayList

function Test-CommandPresent {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# winget export を一度だけ実行してパッケージ ID をキャッシュ。
$script:WingetCache = $null
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
    } catch {
        # winget が無い / 失敗 → 空キャッシュで続行
    } finally {
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    $script:WingetCache = $ids
    return $ids
}

function Test-WingetInstalled {
    param([string]$Id)
    return (Get-WingetIds).ContainsKey($Id)
}

function Show-Required {
    param([string]$Name, [scriptblock]$Test)
    $ok = $false
    try { $ok = [bool](& $Test) } catch {}
    if ($ok) {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline
        Write-Host "  $Name"
    } else {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2717) -ForegroundColor Red -NoNewline
        Write-Host "  $Name"
        [void]$requiredMissing.Add($Name)
    }
}

function Show-Optional {
    param([string]$Name, [string]$Consequence, [scriptblock]$Test)
    $ok = $false
    try { $ok = [bool](& $Test) } catch {}
    if ($ok) {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline
        Write-Host "  $Name"
    } else {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2717) -ForegroundColor Red -NoNewline
        Write-Host "  $Name"
        Write-Host "      $([char]0x2514) skip 可: $Consequence" -ForegroundColor DarkGray
        [void]$optionalMissing.Add($Name)
    }
}

Write-Host ""
Write-Host "Class setup status (Windows)" -ForegroundColor White
Write-Host ""
Write-Host "[必須]" -ForegroundColor White
Show-Required "PowerShell 7"       { Test-CommandPresent 'pwsh' }
Show-Required "git"                { (Test-CommandPresent 'git')  -or (Test-WingetInstalled 'Git.Git') }
Show-Required "GitHub CLI (gh)"    { (Test-CommandPresent 'gh')   -or (Test-WingetInstalled 'GitHub.cli') }
Show-Required "uv"                 { (Test-CommandPresent 'uv')   -or (Test-WingetInstalled 'astral-sh.uv') }
Show-Required "Visual Studio Code" { (Test-CommandPresent 'code') -or (Test-WingetInstalled 'Microsoft.VisualStudioCode') }

Write-Host ""
Write-Host "[任意]" -ForegroundColor White
Show-Optional "GitHub Desktop" "git CLI / VS Code Source Control パネルのみで Git 操作" {
    (Test-Path (Join-Path $Env:LOCALAPPDATA 'GitHubDesktop\GitHubDesktop.exe')) -or `
    (Test-WingetInstalled 'GitHub.GitHubDesktop')
}
Show-Optional "PYTHONUTF8 = 1 (User)" "Python I/O が cp932 既定 / cross-platform 注意" {
    [Environment]::GetEnvironmentVariable('PYTHONUTF8','User') -eq '1'
}

function Get-PromptState {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 'missing' }
    try {
        $content = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch { return 'missing' }
    if (-not $content) { return 'missing' }
    if ($content -match '# >>> class-setup prompt >>>') { return 'ours' }
    # コメント行を除外して既存プロンプト設定パターンを検索
    $stripped = ($content -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($stripped -match 'function\s+(global:)?prompt\b|starship init|oh-my-posh|omp init') {
        return 'existing'
    }
    return 'missing'
}

# OneDrive リダイレクトを考慮し、pwsh 7 が実際に読む $PROFILE と同じ場所を見る。
$pwsh7Profile = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1'
$promptName = 'プロンプトのカスタマイズ (pwsh 7 profile)'
switch (Get-PromptState $pwsh7Profile) {
    'ours' {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline
        Write-Host "  $promptName"
    }
    'existing' {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2713) -ForegroundColor Green -NoNewline
        Write-Host "  $promptName"
        Write-Host "      $([char]0x2514) 既存のプロンプト設定を検出 — class-setup は介入しません" -ForegroundColor DarkGray
    }
    'missing' {
        Write-Host "  " -NoNewline
        Write-Host ([char]0x2717) -ForegroundColor Red -NoNewline
        Write-Host "  $promptName"
        Write-Host "      $([char]0x2514) skip 可: 既定のプロンプトのまま" -ForegroundColor DarkGray
        [void]$optionalMissing.Add('プロンプトのカスタマイズ')
    }
}

$vscodeSettings = Join-Path $Env:APPDATA 'Code\User\settings.json'
Show-Optional "VS Code 既定ターミナル = pwsh 7" "VS Code ターミナルを毎回明示選択" {
    (Test-Path $vscodeSettings) -and `
    ([System.IO.File]::ReadAllText($vscodeSettings, [System.Text.Encoding]::UTF8) -match '"terminal\.integrated\.defaultProfile\.windows"\s*:\s*"PowerShell"')
}

Write-Host ""
Write-Host "Summary" -ForegroundColor White

if ($requiredMissing.Count -eq 0 -and $optionalMissing.Count -eq 0) {
    Write-Host "  全て OK です。" -ForegroundColor Green
} else {
    if ($requiredMissing.Count -gt 0) {
        Write-Host "  必須: $($requiredMissing.Count) 件不足 → " -NoNewline
        Write-Host "setup.ps1 の実行を推奨" -ForegroundColor Yellow
    }
    if ($optionalMissing.Count -gt 0) {
        Write-Host "  任意: $($optionalMissing.Count) 件不足 → 帰結を理解していれば skip 可"
    }
    Write-Host ""
    Write-Host "セットアップ:"
    Write-Host '  powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/setup.ps1 | iex"'
}
Write-Host ""
