# Merak Video for ComfyUI

[English](README.md) · **中文**

在 ComfyUI 里用 [merak](https://merakcompute.ai) 上的 **MiniMax-H3** 生成视频，支持文生视频和图生视频。
渲染在 merak 的 GPU 上完成，你的电脑只需要能跑起 ComfyUI —— 这个节点不需要本地显卡，也不需要额外装任何依赖。

## 一行命令安装

已经装好 ComfyUI 了？把下面对应你系统的那一行复制到终端里回车即可。
它会自动找到 ComfyUI 文件夹，把节点装进去，并保存你的 API key。

**macOS / Linux** —— 打开**终端**（Mac 上按 `⌘ 空格`，输入 `Terminal` 回车）：

```bash
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh | sh
```

**Windows** —— 打开 **PowerShell**（按 Windows 键，输入 `PowerShell` 回车）：

```powershell
irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1 | iex
```

脚本会先显示找到的 ComfyUI 位置，然后让你输入 merak API key：
从 [merak 控制台](https://merakcompute.ai) 复制 key 粘贴进去回车即可。装完后重启 ComfyUI。

两个系统的命令不一样，是因为 Windows 上没有 `sh`，PowerShell 也无法执行 shell 语法 ——
但两个安装脚本做的事情、顺序和参数完全一致。

还没有 ComfyUI？请先看 [安装 ComfyUI](#安装-comfyui)，装好后再回到这里。

再运行一次这行命令就是升级；旧版本会保留在同级目录下的 `merak-comfyui-node.previous`。

### 如果没找到 ComfyUI，或者你不想被提问

把答案直接写在命令里。macOS / Linux：

```bash
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh \
  | sh -s -- --key "你的KEY" --path "/path/to/ComfyUI"
```

Windows：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1))) -ApiKey "你的KEY" -ComfyPath "C:\path\to\ComfyUI"
```

| 参数 | 说明 |
|---|---|
| `--key` / `-ApiKey` | 直接给出 API key，不再提问 |
| `--path` / `-ComfyPath` | 指定 ComfyUI 文件夹，用于自动查找失败时 |
| `--lang en\|zh` / `-Lang` | 提示语言，默认跟随系统 |
| `--yes` / `-Yes` | 全程不提问 —— 缺信息时直接报错退出 |
| `--no-scan` / `-NoScan` | 只用记录路径和默认路径，不搜索磁盘 |
| `--detect-only` / `-DetectOnly` | 只列出找到的所有 ComfyUI 文件夹，然后退出 |

安装脚本只会写两个地方：它报告的那个 ComfyUI 文件夹下的
`custom_nodes/merak-comfyui-node`，以及 key 文件 `~/.merak/api_key`。

### 它是怎么找到 ComfyUI 的

ComfyUI 在不同系统上的安装位置并不统一，但每个安装的内部结构是一样的：
`<base>/custom_nodes` 和 `main.py` 在同一层；而且安装它的那些工具都会把路径记录下来。
所以脚本按“便宜且精确”的顺序依次查找，只有全都落空时才去扫描磁盘：

1. `--path`，或环境变量 `COMFYUI_PATH`
2. 桌面版应用自己的记录 —— `installations.json`（它创建过的每个安装），
   旧版本则是 `config.json` 和 `extra_models_config.yaml`
3. `comfy-cli` 的 `config.ini`，里面记着它的 workspace
4. 当前正在运行的 ComfyUI 进程
5. 各种默认位置 —— `ComfyUI-Installs`、`Documents/ComfyUI`、Windows 便携版、`/opt` 等
6. 系统文件索引：macOS 用 Spotlight，Linux 用 `plocate` —— 都是瞬间返回
7. 限定深度地遍历用户目录和磁盘根目录，跳过 `node_modules`、`site-packages` 之类的目录

第 1–6 步基本是瞬间完成的。第 7 步在 macOS 和 Linux 上需要几秒；
Windows 没有可查询的文件索引，可能要花上一分钟，用 `-NoScan` 可以跳过。

只有当 `custom_nodes` 旁边还有 `main.py`、`comfyui_version.py` 或 `comfy/` 时，
才算是一个确定的 ComfyUI 安装；其它的会标上 `(?)` 并额外确认一次。
找到多个时脚本会让你选。想只看结果、不做安装，加 `--detect-only` / `-DetectOnly`。

## 手动安装

```bash
cd ComfyUI/custom_nodes
git clone https://github.com/snarkify/merak-comfyui-node.git
```

然后保存 key：

```bash
mkdir -p ~/.merak
printf '%s\n' "你的KEY" > ~/.merak/api_key
chmod 600 ~/.merak/api_key
```

Windows 上这个文件是 `C:\Users\<你的用户名>\.merak\api_key` —— 纯文本、UTF-8、key 单独一行。

之后重启 ComfyUI。需要 Python 3.10 或更高版本。想确认是否加载成功，双击画布搜索 **Merak**，
应该能看到 *Merak Generate Video* 和 *Merak Fetch Video (by id)*。

从 Dock 或开始菜单启动的 ComfyUI 读不到你的 shell 配置，所以 key 文件是最可靠的方式。
如果是从终端启动的，用环境变量 `MERAK_API_KEY` 也可以。

`team_id` 可以填在节点上，或放进 `MERAK_TEAM_ID` —— 在 merak 控制台的网址里能找到它。

## 安装 ComfyUI

已经在用 ComfyUI 的可以跳过这一节。

**Windows 或 macOS，最简单 —— 桌面版应用。** 从
[comfy.org/download](https://www.comfy.org/download) 下载安装包，打开后按提示装完即可。
它会把 ComfyUI 文件夹放在 `Documents/ComfyUI`，上面的一行命令能自动找到。

**Windows，便携版。** 从[发布页](https://github.com/comfyanonymous/ComfyUI/releases)下载
`ComfyUI_windows_portable_nvidia.7z`，用 [7-Zip](https://www.7-zip.org/) 解压到比如 `C:\` 下面，
然后用 `run_nvidia_gpu.bat` 启动 —— 没有 NVIDIA 显卡就用 `run_cpu.bat`。
两种方式都不影响 Merak，它的渲染本来就在 merak 的 GPU 上跑。

**macOS、Linux 或从源码装。** 需要 Python 3.10+ 和 git：

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python main.py
```

然后在浏览器打开 <http://127.0.0.1:8188>。Linux 上请先装好对应你显卡的 PyTorch ——
见 [ComfyUI 的 README](https://github.com/comfyanonymous/ComfyUI#installing)。

## 使用

添加 **video/merak → Merak Generate Video**，填好 prompt，选一个 clip，然后排队执行。
视频会保存到输出目录的 `video/merak_00001_.mp4`，并在节点上直接预览。
改 `filename_prefix` 可以换子目录，或加上 `%date:yyyy-MM-dd%` 这样的占位符。

把图片接到 `first_frame`、`last_frame`（或两个都接）就变成图生视频。

节点以 **VIDEO** 类型输出，可以接 Save Video、Trim Video、Get Video Components；
同时还输出 **video_path**，供需要磁盘文件路径的节点使用。

**Merak Fetch Video (by id)** 用来重新下载一个已经提交过的渲染 —— 如果轮询超时了就用它。
超时并不会取消服务端的任务。

`examples/merak-video.json` 是一个现成的工作流，拖到画布上即可。

## 服务规格

| | |
|---|---|
| Clip | `480p/243 帧（约 10.1 秒）`、`720p/243`、`480p/22（约 0.9 秒）` |
| 画面比例 | `16:9`、`9:16`、`1:1` —— 关键帧会被适配到所选画布 |
| Prompt | 最多 7000 字符 |
| 音频 | 每个 clip 都自带，已混流 |
| 关键帧 | 边长 256–5760 px，比例 0.4–2.5，≤30 MB |

22 帧那档超出了规格（H3 的设计区间是 5–15 秒），因此不是默认值。

设定 seed 可以让渲染可复现；填 `-1` 时由服务端随机选择并且不会告诉你用了哪个（`0` 是一个真实的 seed）。

## 常见问题

| | |
|---|---|
| 安装脚本提示找不到 ComfyUI | 先用 `--detect-only` / `-DetectOnly` 看看它找到了什么，再用 `--path` / `-ComfyPath` 指定 ComfyUI 文件夹 |
| 装到了错误的那个 ComfyUI | 用 `--path` / `-ComfyPath` 指定，节点会装到你指定的位置 |
| 重启后搜不到 **Merak** 节点 | 确认节点在 `ComfyUI/custom_nodes/merak-comfyui-node` 下，并查看 ComfyUI 控制台里的报错 |
| `403 INFERENCE_NOT_ENABLED` | 你的账号没有开通推理权限 |
| `403` / `404` 且提到 team | 你必须是该 team 的**所有者**，仅是成员不够 |
| `401` | key 缺失或已被吊销 —— 检查 `~/.merak/api_key` 里只有 key 本身 |
| 渲染 `FAILED` 且提示 `input image …` | 关键帧超出尺寸或比例限制 —— 不计费 |
| 轮询超时 | 渲染**没有**被取消 —— 用 *Merak Fetch Video* 重新取回 |

## 许可证

[MIT](LICENSE)。
