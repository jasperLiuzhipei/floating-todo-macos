# 可选 Codex 集成

没有 Codex 时，本地添加、勾选、提醒与复盘都可使用。

## 配置

1. 安装并登录 Codex / 提供 Codex 能力的桌面应用。
2. 在终端运行 `codex queue --help`，确认该版本支持向现有对话排队发送消息。
3. 从希望用于工作记录的对话复制 technical thread ID（UUID）。
4. Floating Todo 菜单栏 → 设置 → 填入「Codex 对话 ID」。CLI 路径可留空自动发现。
5. 点击「＋添加」，会打开该对话并发送一条询问任务内容的请求。对话正在忙时，请求会排队。

清空对话 ID 即可恢复默认本地添加。菜单栏「直接添加任务」始终可用。

打开现有对话使用[官方支持的 `codex://threads/<thread-id>` 链接](https://learn.chatgpt.com/docs/reference/commands#deep-links)。该链接本身只负责导航；发送请求使用已安装 CLI 的 `queue` 命令。应用不修改 Codex 的内部数据库。

## 数据写入

应用附带 `Contents/Resources/todo_cli.py`，供 Codex 在收到用户明确任务内容后调用。此可选流程要求环境中有 Python 3。

输入示例（日期应与当前清单一致）：

```json
{
  "id": "a-stable-id-for-this-request",
  "title": "整理明天的讨论提纲",
  "detail": "明确要讨论的问题与预期结果",
  "date": "2026-01-01"
}
```

```bash
python3 scripts/todo_cli.py add \
  --state "$HOME/Library/Application Support/FloatingTodo/tasks.json" \
  --input /tmp/new-task.json
```

脚本和应用共用文件锁，写入前重新读取状态，再原子替换。复用同一 `id` 重试不会重复添加，日期不匹配会拒绝写入。不要把用户输入拼成 shell 代码。

本项目不安装任何个人工作日志插件。若用户已有记录插件，可由 Codex 另行同步；添加到清单并不自动代表已经写入其他日志系统。

## 失败处理

- 未找到 CLI：提示检查配置，并提供本地添加。
- CLI 不支持 `queue`、未登录或对话不可用：显示请求发送失败，不声称任务已创建。
- 排队过程超过30秒：终止该次 CLI 请求，显示失败提示；不会无限重试。
- 对话里只看到询问：正常，需回复具体任务内容后才会新增。
