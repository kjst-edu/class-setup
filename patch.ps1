# class-setup patch.ps1 — 旧 setup.ps1 で生じた状態を修復する。
#
# 修復対象 (idempotent — 何度実行しても安全):
#   1. pwsh 7 profile / VS Code settings.json に付いた UTF-8 BOM を除去
#   2. pwsh 7 が実際に読む profile ($PROFILE) と乖離した場所に置かれた
#      class-setup prompt block を正しい場所へ移行
#      - $HOME\Documents\...  (旧 setup.ps1 の直書きバグ。発見次第無確認で移行)
#      - $env:OneDrive\Documents\... など (OneDrive バックアップを後で OFF にした
#        ときの取り残し。意図的に残しているケースもあるので Y/N 確認してから移行)
#
# 実行:
#   powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/patch.ps1 | iex"

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$fixed = New-Object System.Collections.ArrayList

$ProfileRelPath = 'PowerShell\Microsoft.PowerShell_profile.ps1'
$BlockBegin     = '# >>> class-setup prompt >>>'
$BlockEnd       = '# <<< class-setup prompt <<<'
$BlockPattern   = '(?s)(\r?\n)?' + [regex]::Escape($BlockBegin) + '.*?' + [regex]::Escape($BlockEnd) + '(\r?\n)?'

function Test-HasBom {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        try {
            $head = New-Object byte[] 3
            $n = $fs.Read($head, 0, 3)
            return ($n -eq 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF)
        } finally { $fs.Dispose() }
    } catch { return $false }
}

function Remove-Bom {
    param([string]$Path)
    if (-not (Test-HasBom $Path)) { return $false }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $stripped = New-Object byte[] ($bytes.Length - 3)
    [Array]::Copy($bytes, 3, $stripped, 0, $stripped.Length)
    [System.IO.File]::WriteAllBytes($Path, $stripped)
    return $true
}

# 旧 profile の置き場所候補 (現状の $PROFILE と一致しない可能性があるもの):
#   - $HOME\Documents\...        旧 setup.ps1 がリテラルで書いた場所 (バグ)
#   - $env:OneDrive\...          コンシューマ OneDrive (現在の値)
#   - $env:OneDriveConsumer\...  コンシューマ OneDrive (別変数名)
#   - $env:OneDriveCommercial\...職場/学校用 OneDrive
function Get-LiteralHomeProfilePath {
    return (Join-Path $HOME ('Documents\' + $ProfileRelPath))
}

function Get-OneDriveProfilePaths {
    $set = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in 'OneDrive', 'OneDriveConsumer', 'OneDriveCommercial') {
        $base = [Environment]::GetEnvironmentVariable($name)
        if ($base) { [void]$set.Add((Join-Path $base ('Documents\' + $ProfileRelPath))) }
    }
    return @($set)
}

function Confirm-OneDriveMigration {
    param([string]$Legacy, [string]$Correct)
    Write-Host ""
    Write-Host "  OneDrive 側に class-setup の prompt block を見つけました:" -ForegroundColor Yellow
    Write-Host "    legacy : $Legacy"
    Write-Host "    correct: $Correct"
    Write-Host "  これは過去に OneDrive Documents バックアップを ON にしていた名残です。"
    Write-Host "  意図的に OneDrive 側に置いている場合もあるため確認します。"
    Write-Host "  block を correct (現在の `$PROFILE) へ移行しますか？" -ForegroundColor Cyan
    Write-Host "    y + Enter = 移行する / Enter のみ = 触らない (BOM 除去だけ実施)"
    Write-Host -NoNewline "    > "
    $ans = Read-Host
    return $ans -match '^[yY]$'
}

function Move-PromptBlockToCorrect {
    param([string]$Legacy, [string]$Correct, [System.Text.UTF8Encoding]$Encoding)

    $legacyRaw = [System.IO.File]::ReadAllText($Legacy, [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($legacyRaw, $BlockPattern)
    if (-not $m.Success) { return $null }

    $block = $m.Value.Trim("`r", "`n")
    $action = $null

    $correctDir = Split-Path $Correct
    if (-not (Test-Path $correctDir)) {
        New-Item -ItemType Directory -Path $correctDir -Force | Out-Null
    }

    if (Test-Path $Correct) {
        $correctRaw = [System.IO.File]::ReadAllText($Correct, [System.Text.Encoding]::UTF8)
        if ($correctRaw -notmatch [regex]::Escape($BlockBegin)) {
            $sep = if ($correctRaw.Length -eq 0 -or $correctRaw.EndsWith("`n")) { '' } else { "`r`n" }
            [System.IO.File]::WriteAllText($Correct, $correctRaw + $sep + "`r`n" + $block + "`r`n", $Encoding)
            $action = 'merged'
        } else {
            # 既に正しい場所にあるので legacy 側を消すだけ
            $action = 'already-present'
        }
    } else {
        [System.IO.File]::WriteAllText($Correct, $block + "`r`n", $Encoding)
        $action = 'created'
    }

    # legacy 側から block を削除。残りが空白だけならファイルごと消す。
    $cleaned = $legacyRaw.Remove($m.Index, $m.Length)
    if ($cleaned.Trim() -eq '') {
        Remove-Item $Legacy -Force
        return [pscustomobject]@{ Action = $action; LegacyDeleted = $true }
    } else {
        [System.IO.File]::WriteAllText($Legacy, $cleaned, $Encoding)
        return [pscustomobject]@{ Action = $action; LegacyDeleted = $false }
    }
}

Write-Host ""
Write-Host "== class-setup 修正パッチ ==" -ForegroundColor White
Write-Host ""

# ---- パスの解決 ----
$myDocs         = [Environment]::GetFolderPath('MyDocuments')
$profileCorrect = Join-Path $myDocs $ProfileRelPath
$vscodeSettings = Join-Path $Env:APPDATA 'Code\User\settings.json'

# ---- 1. block の移行 ----
# 候補列挙: 「現 $PROFILE 以外」かつ「存在する」もの。
# OneDrive 側か $HOME 直書きか区別して扱う。
$literalHome      = Get-LiteralHomeProfilePath
$oneDriveProfiles = Get-OneDriveProfilePaths

$allCandidates = @($literalHome) + $oneDriveProfiles |
    Select-Object -Unique |
    Where-Object { -not [string]::Equals($_, $profileCorrect, [StringComparison]::OrdinalIgnoreCase) } |
    Where-Object { Test-Path $_ }

foreach ($legacy in $allCandidates) {
    # block が無いファイルは移行対象外 (BOM 除去フェーズで救う)。
    $raw = [System.IO.File]::ReadAllText($legacy, [System.Text.Encoding]::UTF8)
    if ($raw -notmatch [regex]::Escape($BlockBegin)) { continue }

    # OneDrive 側の取り残しは意図的な可能性があるので確認。
    $isLiteralHome = [string]::Equals($legacy, $literalHome, [StringComparison]::OrdinalIgnoreCase)
    if (-not $isLiteralHome) {
        if (-not (Confirm-OneDriveMigration -Legacy $legacy -Correct $profileCorrect)) {
            Write-Host "  移行スキップ (ユーザ判断): $legacy" -ForegroundColor DarkGray
            continue
        }
    }

    $result = Move-PromptBlockToCorrect -Legacy $legacy -Correct $profileCorrect -Encoding $utf8NoBom
    if ($null -eq $result) { continue }

    switch ($result.Action) {
        'created' {
            Write-Host "  profile を新規作成し block を移行: $profileCorrect" -ForegroundColor Green
            Write-Host "    from: $legacy" -ForegroundColor DarkGray
            [void]$fixed.Add("block 移行 (新規): $legacy")
        }
        'merged' {
            Write-Host "  prompt block を移植: $profileCorrect" -ForegroundColor Green
            Write-Host "    from: $legacy" -ForegroundColor DarkGray
            [void]$fixed.Add("block 移行: $legacy")
        }
        'already-present' {
            Write-Host "  block は既に正しい場所にあり — legacy 側を整理: $legacy" -ForegroundColor DarkGray
            [void]$fixed.Add("legacy 整理: $legacy")
        }
    }
    if ($result.LegacyDeleted) {
        Write-Host "    legacy ファイルは空になったため削除しました" -ForegroundColor DarkGray
    } else {
        Write-Host "    legacy ファイルから block のみ除去しました" -ForegroundColor DarkGray
    }
}

# ---- 2. BOM 除去 ----
# 移行で legacy ファイルが消えていることがあるので Test-Path で再フィルタ。
# 移行スキップした OneDrive 側ファイルも BOM だけは安全に除去できる。
$bomTargets = @($profileCorrect) + $allCandidates + @($vscodeSettings) |
    Select-Object -Unique |
    Where-Object { Test-Path $_ }

foreach ($t in $bomTargets) {
    if (Remove-Bom $t) {
        Write-Host "  BOM 除去: $t" -ForegroundColor Green
        [void]$fixed.Add("BOM 除去: $t")
    }
}

# ---- Summary ----
Write-Host ""
if ($fixed.Count -eq 0) {
    Write-Host "  修正対象なし — 全て OK です。" -ForegroundColor Green
} else {
    Write-Host "  $($fixed.Count) 件修正しました:" -ForegroundColor Green
    foreach ($f in $fixed) { Write-Host "    - $f" -ForegroundColor DarkGray }
    Write-Host ""
    Write-Host "  反映には pwsh 7 を起動し直してください。" -ForegroundColor Cyan
}
Write-Host ""
