# 授業セットアップ

授業で使うツール (Git / GitHub CLI / GitHub Desktop / uv / VS Code) を、対話確認しながら最小限で入れます。

## 使い方

### Mac
ターミナルを開いて、次のコマンドを貼り付け:

```sh
# 1. チェック (何も変更しない)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/check.sh)"

# 2. セットアップ (各ステップで Y/N)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/setup.sh)"
```

### Windows
PowerShell を開いて、次のコマンドを貼り付け:

```pwsh
# 1. チェック
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/check.ps1 | iex"

# 2. セットアップ
powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kjst-edu/class-setup/HEAD/setup.ps1 | iex"
```

セットアップ後にもう一度「1. チェック」を実行すれば、設定状況を確認できます。

## Windows ユーザへ

セットアップ完了後は **PowerShell 7** を使ってください (Windows PowerShell 5.1 ではなく)。スタートメニューで `pwsh` を検索して起動、または VS Code のターミナルを開けば自動で pwsh 7 が起動します。5.1 は UTF-8 テキストをパイプで送ると文字化けすることがあります。

## 必要環境

自分の PC で、自分が管理者アカウントであること。途中でパスワードや UAC ダイアログが何度か出ます — スクリプトがその都度説明します。
