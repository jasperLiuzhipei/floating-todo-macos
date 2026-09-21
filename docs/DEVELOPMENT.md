# 开发与发布

## 结构

- `Sources/main.swift`：AppKit 悬浮窗、内容测量、缩放、原生添加、菜单栏设置、提醒与可选 Codex 入口。
- `Sources/Storage.swift`：数据校验、文件锁、原子写入、每日归档和未完成任务承接。
- `scripts/todo_cli.py`：供外部助手安全追加任务，无第三方 Python 依赖。
- `scripts/build_app.py`：显式部署目标 macOS 13，编译两种架构、合并 Universal binary、打包图标、临时签名和 ZIP。
- `scripts/make_icon.swift`：本项目的程序化应用图标源文件。
- `Tests/`：独立临时目录中的存储行为与 CLI 测试。

## 验证

```bash
python3 scripts/test.py
python3 scripts/build_app.py
"dist/Floating Todo.app/Contents/MacOS/FloatingTodo" --layout-check
"dist/Floating Todo.app/Contents/MacOS/FloatingTodo" --data-dir /tmp/floating-todo-dev
```

布局检查覆盖最小 / 最大宽度和长标题测量；存储检查覆盖首启、跨日快照、未完成承接、重试、重复 ID、损坏数据保留。UI 仍需手动验证：首次添加、勾选撤销、长任务换行、精简展开、小尺寸标题栏、拖动手柄、关闭后双击重开。

测试中不要使用真实工作数据。`--data-dir` 可隔离任务与设置 JSON；窗口位置、缩放、精简状态仍保存在该应用的 macOS UserDefaults 中。

## 数据约定

`tasks.json`：`date`、`tasks`、`reminderShown`、`opacity`。每项任务有稳定 `id`、`title`、`detail`、`done`，完成时可有 ISO8601 `completedAt`。

`settings.json`：提醒开关、小时、分钟、IANA 时区，以及可选的 Codex 对话 ID / CLI 路径。缺省字段使用默认值；格式错误会保留原文件并显示错误。

变更格式必须保持兼容或提供显式迁移。未来加入进度复盘字段时，应保留旧的勾选语义，不把未知状态推断成完成。

## 发布

1. 更新 `VERSION`、`CHANGELOG.md` 和文档。
2. 运行测试和 Universal 构建，检查 ZIP 解压后的签名与架构。
3. 为版本创建 `vX.Y.Z` tag；GitHub Actions 中手动运行 **Release macOS**，输入该 tag，即可构建并上传 ZIP 与 SHA-256。
4. 也可使用 `gh release create` 上传本地已验证的产物。不要把 `.app`、个人清单或编译缓存提交进 Git。

构建使用 ad-hoc 签名，不等同于 Developer ID 身份签名或公证。若未来引入 Apple 开发者凭据，应只放在受保护的 CI Secrets 中，不能写入源码。优先完成签名公证，再考虑自动更新。

## 当前架构取舍

使用原生 AppKit，无嵌入式浏览器或服务器。通过固定逻辑画布缩放控件，标题栏预留不缩放的区域。基础宽度由标题测量决定，任务列表高度超出屏幕时滚动。文件变更轮询约1秒，提醒轮询约15秒。
