<p align="center"><img src="llm_lookup/appicon.png" width="128" alt=""></p>

<h1 align="center">划词查词</h1>

<p align="center">macOS 上用大模型翻译、解析屏幕上的文字。三指轻点或按 ⌥R，浮窗里流式显示释义。</p>

---

基于 [Hammerspoon](https://www.hammerspoon.org/)，用来替代系统自带的三指轻点「查询」词典。

## 功能

- **三指轻点 / ⌥R**：有选中文字就解析选中的；没有就查鼠标指着的词，并把所在句子作为上下文一起发给模型，按语境给出释义。
- **按内容类型输出**：单词给音标、词性、释义、例句；句子给译文和难点解析；代码、报错、术语给解释。网址、路径、`os.path.join` 这类整段识别。
- **多种模型来源**：
  - 本机的 Claude Code、Codex，或任意命令行工具。
  - OpenAI / Anthropic 格式的接口，可自定义地址、模型和思考强度。
  - 可以存多套配置，在设置面板或菜单栏里切换，并一键测试首字耗时。
- **设置面板**：Apple 风格，改动立即生效。可以配置快捷键、浮窗尺寸和提示词。
- **API Key 存在钥匙串里**，不出现在配置文件和进程参数中。

### 各应用的取词方式

| 场景 | 方式 |
| --- | --- |
| 原生应用、Safari | 通过辅助功能读取鼠标位置的文字 |
| Ghostty | 按终端字符网格换算鼠标位置，支持回滚历史 |
| Chrome 网页、Cursor / VS Code | 读不到时模拟双击选词再复制，剪贴板会恢复原样 |

## 安装

1. 安装 Hammerspoon，并在「系统设置 › 隐私与安全性 › 辅助功能」里允许它。
2. 安装 Xcode 命令行工具：`xcode-select --install`。首次启动时会用它编译三指检测程序 `tapwatch`。
3. 把代码放进 Hammerspoon 的配置目录：

   ```sh
   git clone https://github.com/liuzemei/llm-lookup.git
   ln -s "$PWD/llm-lookup/llm_lookup" ~/.hammerspoon/llm_lookup
   ```

4. 在 `~/.hammerspoon/init.lua` 里加上：

   ```lua
   require("hs.ipc") -- 可选：让终端里的 `hs` 命令可用
   llmLookup = require("llm_lookup").start()
   ```

5. 重新载入 Hammerspoon，从菜单栏的气泡图标打开「设置…」，选择或添加模型配置。
6. 要用三指轻点，先在「系统设置 › 触控板」里关掉「查询与数据检测器」，免得和系统词典同时弹出。

> 可选：把 `/Applications/Hammerspoon.app` 改名为 `划词查词.app`，并把 `llm_lookup/appicon.png` 设成它的自定义图标。打开这个 App 时会直接显示设置面板。

## 文件

| 文件 | 作用 |
| --- | --- |
| `init.lua` | 入口：快捷键、三指轻点、菜单栏、打开 App 时显示面板 |
| `capture.lua` | 取文字：选区、鼠标下的词、Ghostty 网格换算、⌘C / 双击兜底 |
| `backends.lua` | 各模型来源的调用（CLI 子进程 / curl 流式请求）、钥匙串、测试 |
| `config.lua` | 默认配置、多套模型配置、提示词 |
| `popup.lua` / `popup.html` | 结果浮窗 |
| `settings.lua` / `settings.html` | 设置面板 |
| `tapwatch.c` | 独立进程读取触控板原始触点，检测三指轻点，不拦截任何输入 |

## 排查

每次查词都会在 Hammerspoon 控制台记一行，只记来源、应用和取词方式，不记内容，例如 `tap · Cursor · double-click/selection`。取不到文字时，从这里能看出卡在哪一步。
