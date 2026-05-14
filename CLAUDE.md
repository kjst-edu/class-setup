# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Four standalone shell scripts plus a README. End users do not clone this repo — they paste a one-liner from the README that pipes the raw script from `raw.githubusercontent.com/kjst-edu/class-setup/HEAD/...` into bash or PowerShell. There is no build, no tests, no CI, no package manifest.

Audience: students in a class who need Git, GitHub CLI, uv, VS Code (and on Windows: PowerShell 7) installed. All user-facing strings are in Japanese.

## File pairs and their contract

| macOS       | Windows      | Role                                       |
| ----------- | ------------ | ------------------------------------------ |
| `check.sh`  | `check.ps1`  | Diagnostic only — **must have no side effects** |
| `setup.sh`  | `setup.ps1`  | Interactive installer — `y + Enter` runs each step, `Enter` alone skips |

The `check.*` / `setup.*` pair for each OS must stay functionally parallel: same tool list, same required/optional split, same "skip 可: ..." consequence text. When you change one side, change the other.

Each step is labeled `[必須]` (required for class) or `[任意]` (optional, with the consequence of skipping spelled out). The summary at the end warns separately about skipped required vs optional items.

## Running locally for testing

```sh
bash check.sh          # macOS diagnostic
bash setup.sh          # macOS interactive install
```

```powershell
pwsh -File check.ps1   # Windows diagnostic
pwsh -File setup.ps1   # Windows interactive install
```

There is no automated test harness. Verify changes by running the scripts on a real macOS / Windows machine (or VM) and observing the prompts and final state.

## Architecture decisions worth knowing

**Re-runnable prompt injection.** `setup.sh` / `setup.ps1` edit `~/.zshrc` / `Documents\PowerShell\Microsoft.PowerShell_profile.ps1` by injecting a block delimited by `# >>> class-setup prompt >>>` / `# <<< class-setup prompt <<<`. Re-running replaces the block in place rather than appending. The `check` scripts and `setup` scripts share a `prompt_state` / `Get-PromptState` function that distinguishes three states: `ours` (our marker present → managed), `existing` (any other prompt config detected → leave alone, do not overwrite), `missing` (no prompt config → safe to inject). Preserve all three branches when editing.

**Windows: bootstrap shell ≠ target shell.** `setup.ps1` is launched from Windows PowerShell 5.1 (the `powershell -c "irm ... | iex"` one-liner from the README), but every path it writes to is the **pwsh 7** location (`Documents\PowerShell\...`, not `Documents\WindowsPowerShell\...`). This is intentional: students are pushed onto pwsh 7 because 5.1 mangles UTF-8 through pipes. Don't "fix" this by writing to the 5.1 profile path.

**winget install strategy.** `Install-WingetPackage` tries `--scope user` first to avoid UAC, falls back to system-wide install only if that fails. The fallback is genuinely needed for `Microsoft.PowerShell` (and sometimes `Git.Git`), which have no user-scope installer; the other packages succeed in user scope. A real-machine test on an admin account showed UAC did not visibly steal focus during fallback, so no pre-warning / countdown is shown — if you reintroduce one, justify it against that finding. If you add a new installable, route it through `Install-WingetPackage`.

**Detection without `winget list`.** The check scripts call `winget export` once and cache the parsed package-identifier set (`Get-WingetIds`). Tools are considered installed if either the command is on `PATH` **or** the winget ID is in that cache — this catches tools installed by winget whose `PATH` entry only appears in new shells.

**TTY-conditional color.** `check.sh` / `setup.sh` only emit ANSI escapes when stdout is a TTY (`[ -t 1 ]`). Don't unconditionally embed escape sequences.

**File encoding.** `.ps1` files must be UTF-8 **without BOM** (a recent commit specifically stripped BOMs). The PowerShell scripts call `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` at the top because they run inside a fresh `powershell -c` subprocess where setting it doesn't leak back to the user's shell.

**README code blocks are one-command-per-block on purpose.** The Claude.ai / GitHub UI renders a copy button per fenced block, so each install command is in its own fence to give students a single-click copy. Don't merge them.
