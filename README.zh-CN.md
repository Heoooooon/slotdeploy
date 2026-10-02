[English](README.md) · **简体中文** · [日本語](README.ja.md) · [한국어](README.ko.md)

# slotdeploy

**让非开发人员只需一句“发布到 preview”，也不用担心把预览服务器搞坏。**

设计师、市场和运营同事可以通过 AI 代理（或一条终端命令）把自己的修改发布到预览服务器。
如果修改构建失败，或者服务没能正常启动，**预览服务器会继续展示之前的版本。**
生产（`main`）分支永远不会被改动。是否发布到生产，由人在确认后决定。

![slotdeploy 演示：正常修改会上线，构建失败的修改会被拒绝，页面保持上一个版本](demo/demo.gif)

- 只有两个 bash 脚本（`bin/slotdeploy`、`bin/slotdeploy-push`），只依赖 `bash`、`git` 和 `curl`。
- 服务器通过 systemd 定时器（Linux）或 launchd（macOS）每分钟检查一次 `preview` 分支。
- 在 macOS 自带的 bash 3.2 上也能运行。

## 为什么安全

```
同事的电脑                                 预览服务器
slotdeploy-push push "修改横幅"            slotdeploy watch  (每分钟)
  1. 提交到工作分支 (work/...)               1. preview 有变化吗?
  2. 推送工作分支作为备份                    2. 在空闲槽位 (a 或 b) 中 install -> build -> check
  3. 把 preview 分支指向该提交               3. 通过后原子切换 current 链接 -> 重启
     (绝不推送 main)                         4. 健康检查失败则立即切回上一个槽位
                                             5. 结果记为一行日志
```

| 情况 | 结果 |
|---|---|
| 构建失败（类型错误等） | 不切换链接，继续使用之前的构建。`FAIL ... build failed, kept 1a2b3c4` |
| 构建成功但服务起不来 | 链接恢复到上一个槽位并重启。`FAIL ... health failed, kept ...` |
| 同一个失败的提交 | 不会每分钟重复构建。有新提交时才会重试 |
| 两次部署重叠 | 通过锁保证只有一个在执行。已退出进程遗留的锁会被自动清理 |
| 想要撤回 | `slotdeploy-push rollback prev` / `yesterday` / `<提交>` —— 只移动 preview，本地文件保持不变 |

客户端从不推送 `main`，也从不执行 `git reset` 或 `git stash`。即使你是在 `main` 上做的修改，也会先把改动转移到新的工作分支再推送。

## 安装

```bash
git clone https://github.com/Heoooooon/slotdeploy.git
sudo install -m 755 slotdeploy/bin/slotdeploy slotdeploy/bin/slotdeploy-push /usr/local/bin/
```

## 服务器配置

1. 编写配置文件 —— 示例：[Next.js](examples/nextjs/slotdeploy.env)、[静态站点](examples/static/slotdeploy.env)

   ```ini
   REPO_URL=git@github.com:example/myapp.git
   BRANCH=preview
   ROOT=/srv/myapp
   INSTALL_CMD=npm ci
   BUILD_CMD=npm run build
   CHECK_CMD=test -f .next/BUILD_ID          # 切换前必须通过
   RESTART_CMD=sudo systemctl restart myapp
   HEALTH_URL=http://127.0.0.1:3000/          # 切换后检查,失败则切回
   ```

   | 键 | 说明 | 默认值 |
   |---|---|---|
   | `REPO_URL` | git 远程地址 | （必填） |
   | `BRANCH` | 要监视的分支 | `preview` |
   | `ROOT` | 工作目录：`ROOT/slots/a`、`ROOT/slots/b`、`ROOT/current`（符号链接） | （必填） |
   | `INSTALL_CMD`、`BUILD_CMD` | 在空闲槽位中执行 | 无 |
   | `CHECK_CMD` | 切换**前**的检查。失败时不会动正在运行的服务 | 无 |
   | `RESTART_CMD` | 切换后执行 | 无 |
   | `HEALTH_URL` | 切换**后**用 `curl -f` 检查。失败则恢复上一个槽位 | 无 |
   | `HEALTH_RETRIES`、`HEALTH_INTERVAL` | 健康检查次数 / 间隔（秒） | `30`、`2` |
   | `SHARED_DIR` | 不在 git 中的文件(`.env` 等)，复制到每个槽位 | 无 |
   | `KEEP` | 重新构建同一槽位时保留的路径 | `node_modules` |

   加载配置文件时，值不会被 shell 求值(只有命令类的键会在对应步骤中通过 `bash -c` 执行)。未知的键会报错并被拒绝。

2. 让应用服务从 `ROOT/current` 运行 —— [myapp.service](examples/nextjs/myapp.service)、[nginx.conf](examples/static/nginx.conf)。
   如果 `ROOT/current` 已经是一个真实目录，请先把它移走（slotdeploy 会拒绝替换它）。
3. 注册定时器 —— [systemd](examples/systemd/)、[launchd](examples/launchd/com.example.slotdeploy.plist)

   ```bash
   slotdeploy -c /srv/myapp/slotdeploy.env deploy   # 第一次手动部署
   slotdeploy -c /srv/myapp/slotdeploy.env status
   tail -f /srv/myapp/slotdeploy.log
   ```

日志示例：

```
2026-05-04 10:12:31 OK   preview 3f9c1d2 slot=b 58s | Update opening hours
2026-05-04 10:27:05 FAIL preview 8e41a7b build failed, kept 3f9c1d2 (slot=b) | Type error: Property 'title' does not exist
```

最近一次失败构建的完整输出保存在 `ROOT/logs/last-failed.log`。

## 同事的电脑（客户端）

```bash
slotdeploy-push start                   # 开始修改前:基于当前 preview 新建工作分支
# ... 修改文件 ...
slotdeploy-push push "修改横幅文字"       # 提交 -> 备份工作分支 -> 发布到 preview
slotdeploy-push status                  # 查看 preview 上现在是什么
slotdeploy-push rollback prev           # 回到上一个版本
slotdeploy-push rollback yesterday      # 回到今天 0 点之前的最后状态
slotdeploy-push rollback 1a2b3c4        # 回到指定提交
```

可通过环境变量或 `git config` 配置：`slotdeploy.remote`（origin）、`slotdeploy.branch`（preview）、`slotdeploy.prefix`（work/）、`slotdeploy.protected`（"main master"）。

## 接入 AI 代理

把 [examples/agent-skill/SKILL.md](examples/agent-skill/SKILL.md) 放进代理的技能（skills）目录后，
当有人说“发布到 preview”或“把预览回滚到昨天”时，代理就会执行上面的命令。
技能中写明：代理不做生产部署，发布到生产前必须请人确认。

## 本地试用（无需服务器）

```bash
source demo/sandbox.sh      # 在 /tmp/slotdeploy-demo 中创建远程仓库、服务器和同事的克隆
edit_page "Hello"; slotdeploy-push push "hello"; slotdeploy watch; site
break_build; slotdeploy-push push "broken"; slotdeploy watch; site   # 页面保持上一个版本
```

## 测试

```bash
bash test/run.sh            # 真实的 bare git 远程仓库 + 会成功/失败的模拟构建
shellcheck bin/* test/run.sh demo/sandbox.sh
```

覆盖内容：构建、健康检查或检查失败时保留之前的版本;失败的提交不重试;锁;回滚（prev / yesterday / 提交）不改动本地文件;远程 `main` 不变;拒绝受保护分支;配置值不会被执行。

## 不做的事

- 生产部署。slotdeploy 面向预览服务器。
- 零停机保证。重启期间可能会有短暂中断（静态站点只切换链接，所以没有中断）。
- 构建超时限制。需要的话可以这样包一层：`BUILD_CMD=timeout 600 npm run build`。

## 许可证

MIT
