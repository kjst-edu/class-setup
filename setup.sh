#!/usr/bin/env bash
# class-setup setup.sh — interactive installer for macOS.
# 各ステップで Y/N を聞きながら、授業用ツールと設定を入れる。
# 副作用なしの状態確認は check.sh を使う。

# Colors (only when stdout is a TTY)
if [ -t 1 ]; then
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  CYAN=$'\033[36m'
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN= RED= YELLOW= CYAN= DIM= BOLD= RESET=
fi

REQUIRED_SKIPPED=()
OPTIONAL_SKIPPED=()
TOTAL=8
CURRENT=0

ask() {
  local prompt="$1"
  printf '%s' "$prompt"
  local ans=""
  read -r ans
  case "$ans" in
    y|Y) return 0 ;;
    *) return 1 ;;
  esac
}

countdown() {
  local n="$1"
  printf "  %s秒後に開始します..." "$n"
  while [ "$n" -gt 0 ]; do
    printf "  %s" "$n"
    sleep 1
    n=$((n - 1))
  done
  printf "\n\n"
}

# inject_block FILE BEGIN END BODY
#   既存ブロックがあれば置換、なければ末尾に追記。
inject_block() {
  local file="$1" begin="$2" end="$3" body="$4"
  local dir
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  [ -f "$file" ] || touch "$file"

  if grep -qF "$begin" "$file"; then
    local tmp_repl tmp_out
    tmp_repl=$(mktemp)
    tmp_out=$(mktemp)
    printf '%s\n%s\n%s\n' "$begin" "$body" "$end" > "$tmp_repl"
    awk -v begin="$begin" -v end="$end" -v repl="$tmp_repl" '
      $0 == begin {
        while ((getline line < repl) > 0) print line
        close(repl)
        skip = 1
        next
      }
      skip && $0 == end { skip = 0; next }
      !skip { print }
    ' "$file" > "$tmp_out"
    mv "$tmp_out" "$file"
    rm -f "$tmp_repl"
  else
    printf '\n%s\n%s\n%s\n' "$begin" "$body" "$end" >> "$file"
  fi
}

ensure_brew_on_path() {
  if command -v brew >/dev/null 2>&1; then return; fi
  for prefix in /opt/homebrew /usr/local; do
    if [ -x "$prefix/bin/brew" ]; then
      eval "$("$prefix/bin/brew" shellenv)"
      return
    fi
  done
}

label_required() {
  CURRENT=$((CURRENT + 1))
  printf "\n%s[%d/%d] %s%s  %s[必須]%s\n" \
    "$BOLD" "$CURRENT" "$TOTAL" "$1" "$RESET" "$CYAN" "$RESET"
}

label_optional() {
  CURRENT=$((CURRENT + 1))
  printf "\n%s[%d/%d] %s%s  %s[任意]%s\n" \
    "$BOLD" "$CURRENT" "$TOTAL" "$1" "$RESET" "$YELLOW" "$RESET"
  printf "  %sスキップ時: %s%s\n" "$DIM" "$2" "$RESET"
}

ASK_PROMPT="インストールしますか？  y + Enter = 実行 / Enter のみ = スキップ
> "

already_present() { printf "  %sインストール済み — skip%s\n" "$DIM" "$RESET"; }
skipped_required() { REQUIRED_SKIPPED+=("$1"); printf "  %sスキップしました%s\n" "$DIM" "$RESET"; }
skipped_optional() { OPTIONAL_SKIPPED+=("$1"); printf "  %sスキップしました%s\n" "$DIM" "$RESET"; }

print_sudo_warning() {
  cat <<EOF

${BOLD}================================================${RESET}
${BOLD}これから macOS のパスワードを聞かれます${RESET}
${BOLD}================================================${RESET}
ターミナルに "Password:" と出たら、Mac にログインする
ときのパスワードを入力して Enter を押してください。

  ${YELLOW}画面には何も表示されません${RESET} (アスタリスクも出ません)
  「効いてない」ように見えますが、ちゃんと入力されています

${BOLD}================================================${RESET}

EOF
}

# --- header ---
cat <<EOF

${BOLD}== クラスセットアップ (macOS) ==${RESET}

${CYAN}[必須]${RESET} = 授業で前提とするもの、欠けると困る
${YELLOW}[任意]${RESET} = 入れた方が便利だが、帰結を理解して skip するなら自由

各ステップで「${GREEN}y${RESET} + Enter」で実行、「Enter」のみでスキップ。
途中で Ctrl+C を押せばいつでも中断できます。

EOF

# --- 1. Homebrew ---
label_required "Homebrew (パッケージマネージャ)"
if command -v brew >/dev/null 2>&1; then
  already_present
elif ask "$ASK_PROMPT"; then
  print_sudo_warning
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ensure_brew_on_path
else
  skipped_required "Homebrew"
fi

# --- 2. Xcode CLT (git, clang, make を含む) ---
label_required "Xcode コマンドラインツール (git を含みます)"
if xcode-select -p >/dev/null 2>&1; then
  already_present
elif ask "$ASK_PROMPT"; then
  printf "\n%sGUI のインストールダイアログが開きます。「インストール」をクリックしてください。%s\n" "$BOLD" "$RESET"
  countdown 2
  xcode-select --install >/dev/null 2>&1 || true
  printf "  ダイアログ完了を待っています... (Ctrl+C で中断可)\n"
  waited=0
  until xcode-select -p >/dev/null 2>&1; do
    sleep 5
    waited=$((waited + 5))
    if [ "$waited" -ge 60 ] && [ $((waited % 60)) -eq 0 ]; then
      printf "  %s%d 分経過...%s\n" "$DIM" "$((waited / 60))" "$RESET"
    fi
    if [ "$waited" -ge 1800 ]; then
      printf "  %s30 分経過したので諦めます。後で xcode-select --install を実行してください。%s\n" "$YELLOW" "$RESET"
      REQUIRED_SKIPPED+=("Xcode CLT")
      break
    fi
  done
  if xcode-select -p >/dev/null 2>&1; then
    printf "  %sインストール完了%s\n" "$GREEN" "$RESET"
  fi
else
  skipped_required "Xcode CLT"
fi

# --- 3. uv ---
label_required "uv (Python パッケージマネージャ)"
if command -v uv >/dev/null 2>&1; then
  already_present
elif ! command -v brew >/dev/null 2>&1; then
  printf "  %sHomebrew が無いので skip%s\n" "$RED" "$RESET"
  REQUIRED_SKIPPED+=("uv")
elif ask "$ASK_PROMPT"; then
  brew install uv
else
  skipped_required "uv"
fi

# --- 4. ~/.local/bin を PATH に追加 ---
label_required "~/.local/bin を PATH に追加 (uv tool install 先)"
if [[ ":$PATH:" == *":$HOME/.local/bin:"* ]]; then
  already_present
elif ask "$ASK_PROMPT"; then
  inject_block "$HOME/.zshrc" \
    "# >>> class-setup path >>>" \
    "# <<< class-setup path <<<" \
    'export PATH="$HOME/.local/bin:$PATH"'
  export PATH="$HOME/.local/bin:$PATH"
  printf "  %s追記しました%s (~/.zshrc)\n" "$GREEN" "$RESET"
else
  skipped_required "~/.local/bin PATH"
fi

# --- 5. GitHub CLI ---
label_required "GitHub CLI (gh コマンド)"
if command -v gh >/dev/null 2>&1; then
  already_present
elif ! command -v brew >/dev/null 2>&1; then
  printf "  %sHomebrew が無いので skip%s\n" "$RED" "$RESET"
  REQUIRED_SKIPPED+=("gh")
elif ask "$ASK_PROMPT"; then
  brew install gh
else
  skipped_required "gh"
fi

# --- 6. VS Code ---
label_required "Visual Studio Code"
if [ -d "/Applications/Visual Studio Code.app" ]; then
  already_present
elif ! command -v brew >/dev/null 2>&1; then
  printf "  %sHomebrew が無いので skip%s\n" "$RED" "$RESET"
  REQUIRED_SKIPPED+=("Visual Studio Code")
elif ask "$ASK_PROMPT"; then
  brew install --cask visual-studio-code
else
  skipped_required "Visual Studio Code"
fi

# --- 7. GitHub Desktop ---
label_optional "GitHub Desktop" \
  "git CLI / VS Code Source Control パネルのみで Git 操作"
if [ -d "/Applications/GitHub Desktop.app" ]; then
  already_present
elif ! command -v brew >/dev/null 2>&1; then
  printf "  %sHomebrew が無いので skip%s\n" "$RED" "$RESET"
  OPTIONAL_SKIPPED+=("GitHub Desktop")
elif ask "$ASK_PROMPT"; then
  brew install --cask github
else
  skipped_optional "GitHub Desktop"
fi

# --- 8. プロンプトのカスタマイズ ---
label_optional "プロンプトのカスタマイズ (~/.zshrc にプロンプトのカスタマイズを1ブロック追記)" \
  "既定の長いプロンプトのまま"

prompt_state() {
  local file="$HOME/.zshrc"
  if grep -qF "# >>> class-setup prompt >>>" "$file" 2>/dev/null; then
    echo "ours"; return
  fi
  if [ -f "$file" ] && \
     grep -vE '^[[:space:]]*#' "$file" 2>/dev/null | \
     grep -qE '\bPROMPT=|\bPS1=|\bRPROMPT=|starship init|oh-my-posh|oh-my-zsh|powerlevel10k|antigen|zinit|prezto|sheldon'; then
    echo "existing"; return
  fi
  echo "missing"
}

case "$(prompt_state)" in
  ours)
    already_present
    ;;
  existing)
    printf "  %s既存のプロンプト設定を検出 — 上書き回避のため skip%s\n" "$DIM" "$RESET"
    OPTIONAL_SKIPPED+=("プロンプトのカスタマイズ (既存検出)")
    ;;
  missing)
    if ask "$ASK_PROMPT"; then
      inject_block "$HOME/.zshrc" \
        "# >>> class-setup prompt >>>" \
        "# <<< class-setup prompt <<<" \
        'autoload -Uz vcs_info
setopt prompt_subst
zstyle ":vcs_info:git:*" formats " (%b)"
precmd() { vcs_info }
PROMPT="%F{cyan}%1~%f%F{magenta}${vcs_info_msg_0_}%f %# "'
      printf "  %s追記しました%s (新規 zsh セッションで反映)\n" "$GREEN" "$RESET"
    else
      skipped_optional "プロンプトのカスタマイズ"
    fi
    ;;
esac

# --- summary ---
echo ""
echo "${BOLD}== セットアップ終了 ==${RESET}"

if [ "${#REQUIRED_SKIPPED[@]}" -gt 0 ]; then
  echo ""
  echo "${RED}⚠ 以下の [必須] 項目を skip しました。授業の説明と合わない可能性があります:${RESET}"
  for n in "${REQUIRED_SKIPPED[@]}"; do echo "  - $n"; done
fi

if [ "${#OPTIONAL_SKIPPED[@]}" -gt 0 ]; then
  echo ""
  echo "${DIM}スキップした [任意] 項目:${RESET}"
  for n in "${OPTIONAL_SKIPPED[@]}"; do echo "  - $n"; done
fi

echo ""
echo "確認: 次のコマンドで状態を再チェックできます"
echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/check.sh)"'
echo ""
