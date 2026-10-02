[English](README.md) · [简体中文](README.zh-CN.md) · **日本語** · [한국어](README.ko.md)

# slotdeploy

**開発者でなくても「preview に上げて」のひと言で。プレビューサーバーを壊す心配はありません。**

デザイナー、マーケター、運用担当のチームメイトが、AI エージェント（またはターミナルのコマンド 1 行）で修正をプレビューサーバーに反映します。
修正のビルドが失敗したり、サーバーが正常に起動しなかったりした場合でも、**プレビューサーバーは直前の画面をそのまま表示し続けます。**
本番（`main`）ブランチには一切触れません。本番への反映は、人が確認してから行います。

![slotdeploy のデモ：正常な修正は反映され、壊れたビルドは拒否されて直前の画面が維持される](demo/demo.gif)

- Bash コマンド（`bin/slotdeploy`、`bin/slotdeploy-push`）と初期設定ヘルパー。実行に必要なのは `bash`、`git`、`curl` です。
- サーバーは systemd タイマー（Linux）または launchd（macOS）で 1 分ごとに `preview` ブランチを確認します。
- macOS 標準の bash 3.2 でも動作します。

## なぜ安全なのか

```
チームメイトの PC                          プレビューサーバー
slotdeploy-push push "バナー修正"          slotdeploy watch  (1 分ごと)
  1. 作業ブランチ (work/...) にコミット      1. preview は更新された?
  2. 作業ブランチをバックアップ push         2. 空いているスロット (a か b) で install -> build -> check
  3. preview ブランチをそのコミットへ        3. 通過したら current リンクをアトミックに切替 -> 再起動
     (main は絶対に push しない)             4. ヘルスチェック失敗ならすぐ前のスロットへ戻す
                                             5. 結果を 1 行のログに記録
```

| 状況 | 結果 |
|---|---|
| ビルド失敗（型エラーなど） | リンクは切り替えず、直前のビルドが引き続き動く。`FAIL ... build failed, kept 1a2b3c4` |
| ビルドは通ったがサーバーが起動しない | 前のスロットへリンクを戻して再起動。`FAIL ... health failed, kept ...` |
| 同じ失敗コミット | 1 分ごとに再ビルドはしない。新しいコミットが来たら再挑戦 |
| 2 つのデプロイが重なる | ロックで 1 つだけ実行。終了したプロセスが残したロックは自動で片付ける |
| 元に戻したい | `slotdeploy-push rollback prev` / `yesterday` / `<コミット>` — preview を動かすだけで、手元のファイルはそのまま |

クライアントは `main` への push、`git reset`、`git stash` を使いません。`main` の上で修正していた場合も、変更を新しい作業ブランチに移してから push します。

## インストール

```bash
git clone https://github.com/Heoooooon/slotdeploy.git
sh slotdeploy/install.sh --source slotdeploy
```

1 行でインストール（既定は `~/.local/bin`、sudo 不要）:

```sh
curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh
export PATH="$HOME/.local/bin:$PATH"
curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh -s -- update
curl -fsSL https://raw.githubusercontent.com/Heoooooon/slotdeploy/main/install.sh | sh -s -- uninstall
```

`--bin-dir` で保存先、`--ref <branch/tag/commit>` でバージョンを選びます。既定は `main`。削除時も設定・タイマー・デプロイ済みサイトは保持します。

## 初期設定 (v0.2.0)

`slotdeploy init` はリポジトリ、保存先、ブランチ、ビルド・再起動コマンド、ヘルス URL、タイマーを質問します。非対話型:

```bash
slotdeploy -c "$HOME/site/slotdeploy.env" init --yes \
  --repo git@github.com:example/site.git --root "$HOME/site" \
  --install 'npm ci' --build 'npm run build' \
  --health-url http://127.0.0.1:3000/ --timer systemd
```

設定は権限 600 で作成し、既存ファイルは上書きしません。`--timer systemd` は `~/.config/systemd/user`、`--timer launchd` は `~/Library/LaunchAgents` に出力。`--timer none` は設定のみ。`--timer-dir`、`--every 60`、`--name`、`--check` も指定できます。**生成だけで有効化はしません**。表示された有効化コマンドを実行し、初回は手動でデプロイしてください。ログアウト後も systemd を動かすには `loginctl enable-linger "$USER"` が必要です。launchd ユーザーエージェントはログイン中に動きます。

## 通知

Git や設定ファイルではなく、**watcher の環境変数**で指定します。

| サービス | 環境変数 |
|---|---|
| Telegram | `SLOTDEPLOY_TELEGRAM_URL` (完全な `/sendMessage` URL)、`SLOTDEPLOY_TELEGRAM_CHAT_ID` |
| Discord | `SLOTDEPLOY_DISCORD_URL` |
| Slack | `SLOTDEPLOY_SLACK_URL` |

`success`、`failure`、再起動・ヘルス失敗で以前の稼働スロットを復元した場合は追加で `rollback` を送信します。クライアントの rollback はブランチを移動し、watcher がその後のデプロイ結果を通知します。通知エラーはデプロイ結果を変えません。タイムアウトを設定し、ブランチ・コミット・スロット・失敗段階だけを送信します。秘密 URL・チャット ID・応答はログに出さず、ビルドプロセスにも通知の認証情報を渡しません。

systemd は非公開の `EnvironmentFile=` をサービスの drop-in で指定、launchd は非公開の `EnvironmentVariables` またはロード前の `launchctl setenv` を使います。環境を変更したら watcher を再ロード。秘密を共有ログに貼ったりシェルトレースを有効にしたりしないでください。

## サーバーの設定

1. 設定ファイルを書く — 例：[Next.js](examples/nextjs/slotdeploy.env)、[静的サイト](examples/static/slotdeploy.env)

   ```ini
   REPO_URL=git@github.com:example/myapp.git
   BRANCH=preview
   ROOT=/srv/myapp
   INSTALL_CMD=npm ci
   BUILD_CMD=npm run build
   CHECK_CMD=test -f .next/BUILD_ID          # 切り替え前に通過が必要
   RESTART_CMD=sudo systemctl restart myapp
   HEALTH_URL=http://127.0.0.1:3000/          # 切り替え後に確認、失敗したら戻す
   ```

   | キー | 説明 | デフォルト |
   |---|---|---|
   | `REPO_URL` | git リモートの URL | （必須） |
   | `BRANCH` | 監視するブランチ | `preview` |
   | `ROOT` | 作業ディレクトリ。`ROOT/slots/a`、`ROOT/slots/b`、`ROOT/current`（シンボリックリンク） | （必須） |
   | `INSTALL_CMD`、`BUILD_CMD` | 空いているスロットの中で実行 | なし |
   | `CHECK_CMD` | 切り替え**前**のチェック。失敗したら稼働中のサービスには触れない | なし |
   | `RESTART_CMD` | 切り替え後に実行 | なし |
   | `HEALTH_URL` | 切り替え**後**に `curl -f` で確認。失敗したら前のスロットに戻す | なし |
   | `HEALTH_RETRIES`、`HEALTH_INTERVAL` | ヘルスチェックの回数 / 間隔（秒） | `30`、`2` |
   | `SHARED_DIR` | git に入っていないファイル（`.env` など）を各スロットにコピー | なし |
   | `KEEP` | 同じスロットを再ビルドするときに消さないパス | `node_modules` |

   設定値は読み込み時にシェルで評価されません（コマンド系のキーだけが、該当ステップで `bash -c` により実行されます）。未知のキーはエラーとして拒否します。

2. アプリのサービスを `ROOT/current` から起動するようにします — [myapp.service](examples/nextjs/myapp.service)、[nginx.conf](examples/static/nginx.conf)。
   `ROOT/current` に既存の実ディレクトリがある場合は、先に移動してください（実ディレクトリだと slotdeploy は置き換えを拒否します）。
3. タイマーを登録 — [systemd](examples/systemd/)、[launchd](examples/launchd/com.example.slotdeploy.plist)

   ```bash
   slotdeploy -c /srv/myapp/slotdeploy.env deploy   # 最初のデプロイは手動で
   slotdeploy -c /srv/myapp/slotdeploy.env status
   tail -f /srv/myapp/slotdeploy.log
   ```

ログの例：

```
2026-05-04 10:12:31 OK   preview 3f9c1d2 slot=b 58s | Update opening hours
2026-05-04 10:27:05 FAIL preview 8e41a7b build failed, kept 3f9c1d2 (slot=b) | Type error: Property 'title' does not exist
```

失敗したビルドの出力全体は `ROOT/logs/last-failed.log` に残ります。

## チームメイトの PC（クライアント）

```bash
slotdeploy-push start                    # 修正を始める前に：今の preview から新しい作業ブランチを作る
# ... ファイルを修正 ...
slotdeploy-push push "バナーの文言を修正"   # コミット -> 作業ブランチをバックアップ -> preview に反映
slotdeploy-push status                   # いま preview に何が載っているか
slotdeploy-push rollback prev            # ひとつ前に戻す
slotdeploy-push rollback yesterday       # 今日の 0 時より前の最後の状態に戻す
slotdeploy-push rollback 1a2b3c4         # 特定のコミットに戻す
```

設定は環境変数か `git config` で行います：`slotdeploy.remote`（origin）、`slotdeploy.branch`（preview）、`slotdeploy.prefix`（work/）、`slotdeploy.protected`（"main master"）。

## AI エージェントと組み合わせる

[examples/agent-skill/SKILL.md](examples/agent-skill/SKILL.md) をエージェントのスキルフォルダに置くと、
「preview に上げて」「昨日の状態に戻して」といった指示で上のコマンドを実行します。
スキルには、エージェントは本番デプロイを行わず、本番への反映は人に確認を求めるよう書かれています。

クローンしたリポジトリからパッケージを配置:

```bash
mkdir -p "$HOME/.omo/agent/skills" "$HOME/.claude/skills"
cp -R skills/omo/preview-deploy "$HOME/.omo/agent/skills/"
cp -R skills/claude-code/preview-deploy "$HOME/.claude/skills/"
```

スキルを再ロード後、**「preview に上げて」** / **"preview로 올려줘"**。push 成功とサーバーの稼働確認を区別し、未確認の URL は作りません。

## ローカルで試す（サーバー不要）

```bash
source demo/sandbox.sh      # /tmp/slotdeploy-demo にリモート・サーバー・チームメイトの PC を作ります
edit_page "Hello"; slotdeploy-push push "hello"; slotdeploy watch; site
break_build; slotdeploy-push push "broken"; slotdeploy watch; site   # 直前の画面が維持される
```

## テスト

```bash
bash test/run.sh            # 本物の bare git リモート + 成功／失敗する偽のビルド
shellcheck bin/* install.sh test/*.sh demo/sandbox.sh
```

テストには Python 3.12 以上も必要です（ローカル HTTP 通知と plist 検証）。実行バイナリは Bash・Git・curl のみ必要です。
検証している内容：ビルド・ヘルスチェック・事前チェックの失敗時に直前の版を維持、同じ失敗コミットを再試行しない、ロック、ロールバック（prev / yesterday / コミット）で作業ファイルが変わらない、リモートの `main` が変わらない、保護ブランチの拒否、設定値を実行しない。

## やらないこと

- 本番デプロイ。slotdeploy はプレビューサーバー用です。
- 無停止の保証。再起動中は短い切断が起こり得ます（静的サイトはリンクの切り替えだけなので切断なし）。
- ビルドのタイムアウト。必要なら `BUILD_CMD=timeout 600 npm run build` のようにラップしてください。

## ライセンス

MIT
