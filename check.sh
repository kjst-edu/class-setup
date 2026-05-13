#!/usr/bin/env bash
# class-setup check.sh — diagnostic only, no side effects.
# Reports the install state of class tools, splitting required vs optional.

# Colors (only when stdout is a TTY)
if [ -t 1 ]; then
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  DIM=$'\033[2m'
  BOLD=$'\033[1m'
  RESET=$'\033[0m'
else
  GREEN= RED= YELLOW= DIM= BOLD= RESET=
fi

REQUIRED_MISSING=()
OPTIONAL_MISSING=()

check_required() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf "  %s✓%s  %s\n" "$GREEN" "$RESET" "$name"
  else
    printf "  %s✗%s  %s\n" "$RED" "$RESET" "$name"
    REQUIRED_MISSING+=("$name")
  fi
}

check_optional() {
  local name="$1" consequence="$2"; shift 2
  if "$@" >/dev/null 2>&1; then
    printf "  %s✓%s  %s\n" "$GREEN" "$RESET" "$name"
  else
    printf "  %s✗%s  %s\n" "$RED" "$RESET" "$name"
    printf "      %s└ skip 可: %s%s\n" "$DIM" "$consequence" "$RESET"
    OPTIONAL_MISSING+=("$name")
  fi
}

echo ""
echo "${BOLD}Class setup status (macOS)${RESET}"
echo ""
echo "${BOLD}[必須]${RESET}"
check_required "Homebrew"             command -v brew
check_required "Xcode CLT (git)"      xcode-select -p
check_required "uv"                   command -v uv
check_required "GitHub CLI (gh)"      command -v gh
check_required "Visual Studio Code"   test -d "/Applications/Visual Studio Code.app"

echo ""
echo "${BOLD}[任意]${RESET}"
check_optional "GitHub Desktop" \
  "git CLI / VS Code Source Control のみで Git 操作" \
  test -d "/Applications/GitHub Desktop.app"
prompt_state() {
  # echoes "ours" | "existing" | "missing"
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
    printf "  %s✓%s  %s\n" "$GREEN" "$RESET" "プロンプトのカスタマイズ (~/.zshrc)"
    ;;
  existing)
    printf "  %s✓%s  %s\n" "$GREEN" "$RESET" "プロンプトのカスタマイズ (~/.zshrc)"
    printf "      %s└ 既存のプロンプト設定を検出 — class-setup は介入しません%s\n" "$DIM" "$RESET"
    ;;
  missing)
    printf "  %s✗%s  %s\n" "$RED" "$RESET" "プロンプトのカスタマイズ (~/.zshrc)"
    printf "      %s└ skip 可: 既定の長いプロンプトのまま%s\n" "$DIM" "$RESET"
    OPTIONAL_MISSING+=("プロンプトのカスタマイズ")
    ;;
esac

echo ""
echo "${BOLD}Summary${RESET}"

if [ "${#REQUIRED_MISSING[@]}" -eq 0 ] && [ "${#OPTIONAL_MISSING[@]}" -eq 0 ]; then
  echo "  ${GREEN}全て OK です。${RESET}"
  exit 0
fi

if [ "${#REQUIRED_MISSING[@]}" -gt 0 ]; then
  echo "  必須: ${#REQUIRED_MISSING[@]} 件不足 → ${YELLOW}setup.sh の実行を推奨${RESET}"
fi
if [ "${#OPTIONAL_MISSING[@]}" -gt 0 ]; then
  echo "  任意: ${#OPTIONAL_MISSING[@]} 件不足 → 帰結を理解していれば skip 可"
fi

echo ""
echo "セットアップ:"
echo '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/setup.sh)"'

if [ "${#REQUIRED_MISSING[@]}" -gt 0 ]; then
  exit 1
fi
exit 0
