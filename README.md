<p align="center"><img src="llm_lookup/appicon.png" width="128" alt=""></p>

<h1 align="center">划词查询</h1>

<p align="center">macOS 上用大模型翻译、解析屏幕上的文字。三指轻点或按 ⌥R，浮窗里流式显示释义。</p>

---

用来替代系统自带的三指轻点「查询」词典。

## 功能

- **三指轻点 / ⌥R**：有选中文字就解析选中的；没有就查鼠标指着的词，并把所在句子作为上下文一起发给模型，按语境给出释义。
- **快速按两下 ⌥R**：不取屏幕文字，弹出空白问答框，直接输入问题。按一下的查词不受影响。
- **联网搜索**：问答框里由模型决定要不要联网，回答末尾列出来源链接，点开用浏览器打开。查词不联网，速度不变。支持 Claude Code、Codex、OpenAI（Responses 接口）、Anthropic 接口；命令行来源不支持。
- **继续追问**：结果下方有输入框，可以基于当前内容多轮提问（↩ 发送，⇧↩ 换行）。新的查词会开始新的对话。
- **历史记录**：查词和问答有了回答就存在本机，最多 500 条。菜单栏「历史记录…」里可以搜索、复制、删除，或者点「继续追问」在浮窗里接着问。
- **按内容类型输出**：单词给音标、词性、释义、例句；句子给译文和难点解析；代码、报错、术语给解释。网址、路径、`os.path.join` 这类整段识别。
- **多种模型来源**：
  - 本机的 Claude Code、Codex，或任意命令行工具。
  - OpenAI / Anthropic 格式的接口，可自定义地址、模型和思考强度。
  - 可以存多套配置，在设置面板或菜单栏里切换，并一键测试首字耗时。
- **设置面板**：Apple 风格，改动立即生效。可以配置快捷键、浮窗尺寸、提示词和登录时自动打开。
- **API Key 存在钥匙串里**，不出现在配置文件和进程参数中。

### 各应用的取词方式

| 场景 | 方式 |
| --- | --- |
| 原生应用、Safari | 通过辅助功能读取鼠标位置的文字 |
| Ghostty | 按终端字符网格换算鼠标位置，支持回滚历史 |
| Chrome 网页、Cursor / VS Code | 读不到时模拟双击选词再复制，剪贴板会恢复原样 |

## 安装

1. 安装 Xcode 命令行工具：`xcode-select --install`。首次启动时会用它编译三指检测程序 `tapwatch`。
2. 下载代码并运行安装脚本：

   ```sh
   git clone https://github.com/liuzemei/llm-lookup.git
   cd llm-lookup && ./install.sh
   ```

   脚本会在「应用程序」里生成「划词查询.app」并打开。代码从这个目录加载，装好后不要移动或删除它；挪了位置就重新运行一次 `./install.sh`。
3. 在「系统设置 › 隐私与安全性 › 辅助功能」里允许「划词查询」，设置面板顶部有入口。
4. 在设置面板里选择或添加模型配置，需要的话打开「登录时自动打开」。
5. 要用三指轻点，先在「系统设置 › 触控板」里关掉「查询与数据检测器」，免得和系统词典同时弹出。

更新：`git pull` 后从菜单栏图标退出再打开。重新运行 `./install.sh` 一般不用重新授权；如果之后取词没反应，在辅助功能列表里把「划词查询」删掉（－），再打开 App 重新允许。

## 文件

| 文件 | 作用 |
| --- | --- |
| `install.sh` | 生成「划词查询.app」：换名字、图标和标识，去掉用不到的系统集成，重新签名 |
| `llm_lookup/init.lua` | 入口：快捷键、三指轻点、菜单栏、打开 App 时显示面板 |
| `llm_lookup/capture.lua` | 取文字：选区、鼠标下的词、Ghostty 网格换算、⌘C / 双击兜底 |
| `llm_lookup/backends.lua` | 各模型来源的调用（CLI 子进程 / curl 流式请求）、钥匙串、测试 |
| `llm_lookup/config.lua` | 默认配置、多套模型配置、提示词 |
| `llm_lookup/popup.lua` / `popup.html` | 结果浮窗 |
| `llm_lookup/md.js` | 浮窗和历史窗口共用的 Markdown 渲染 |
| `llm_lookup/history.lua` | 历史记录的读写，存在 `~/Library/Application Support/llm-lookup/history.json` |
| `llm_lookup/historyview.lua` / `history.html` | 历史记录窗口 |
| `llm_lookup/settings.lua` / `settings.html` | 设置面板 |
| `llm_lookup/tapwatch.c` | 独立进程读取触控板原始触点，检测三指轻点，不拦截任何输入 |

## 排查

每次查词都会在调试控制台（按住 ⌥ 点菜单栏图标）记一行，只记来源、应用和取词方式，不记内容，例如 `tap · Cursor · double-click/selection`。取不到文字时，从这里能看出卡在哪一步。

## 开发

App 的运行时是 [Hammerspoon](https://www.hammerspoon.org/)（MIT 协议），代码里的 `hs.*` 都是它的接口。`install.sh` 用本机已有的或从 GitHub 下载的官方发布版打包，改完代码按住 ⌥ 点菜单栏图标选「重新载入」即可生效。
