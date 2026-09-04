# Merak Video for ComfyUI

[English](README.md) · **中文**

在 ComfyUI 里用 [merak](https://merakcompute.ai) 上的 **MiniMax-H3** 生成视频，支持文生视频和图生视频。
渲染在 merak 的 GPU 上完成，你的电脑只需要能跑起 ComfyUI —— 这个节点不需要本地显卡，也不需要额外装任何依赖。

## 开始之前

请先准备好：

* **装好的 ComfyUI** —— 还没有？先看 [安装 ComfyUI](#安装-comfyui)，几分钟就能装好
* **一个 merak API key** —— 在 [merak 控制台](https://merakcompute.ai) 获取
* **一个打开的终端** —— macOS 上按 `⌘ 空格` 输入 `Terminal` 回车；
  Windows 上按 Windows 键，输入 `PowerShell` 或 `命令提示符`

不需要显卡。渲染都在 merak 的 GPU 上完成，你的电脑只负责跑 ComfyUI。

## 第 1 步：安装节点

复制对应你系统的那一行，粘贴到终端里回车。

**macOS、Linux：**

```bash
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh | sh
```

**Windows PowerShell：**

```powershell
irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1 | iex
```

**Windows CMD（命令提示符）：**

```batch
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.cmd -o install.cmd && install.cmd && del install.cmd
```

如果报错 `The token '&&' is not a valid statement separator`，说明你在 PowerShell 里，
而不是 CMD；如果报错 `'irm' is not recognized as an internal or external command`，
说明你在 CMD 里，而不是 PowerShell。看提示符就能区分：PowerShell 显示 `PS C:\`，
CMD 只显示 `C:\`。

脚本本身的提示是英文的（这份文档是中文的）。它会打印找到的 ComfyUI 文件夹，并安装到那里。再运行一次就是升级，
旧版本会保留在同级目录下的 `merak-comfyui-node.previous`。

在 WSL 里，如果 ComfyUI 装在 Windows 上，请使用 Windows 安装脚本；只有 ComfyUI
本身也装在 WSL 里时，才使用 shell 安装脚本。

## 第 2 步：粘贴 API key

脚本会主动询问。从 [merak 控制台](https://merakcompute.ai) 复制 key，粘贴进去回车即可。

key 会写入 `~/.merak/api_key`（Windows 上是 `C:\Users\<你的用户名>\.merak\api_key`），
只有你自己可读。如果那里已经存了 key，脚本会保留它，也不会再问。

## 第 3 步：确认加载成功

重启 ComfyUI，双击画布，输入 `Merak`。应该能看到：

* **Merak Generate Video**
* **Merak Fetch Video (by id)**

如果搜不到，见 [常见问题](#常见问题)。

## 第 4 步：生成第一个视频

把 `examples/merak-video.json` 拖到画布上就有一个现成的工作流；
或者自己添加 **video/merak → Merak Generate Video**，写好 prompt，排队执行。
视频会保存到输出目录，并在节点上直接预览。更多用法见 [使用](#使用)。

## 参数

把答案直接写在命令里，就不会有任何提问。macOS / Linux：

```bash
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.sh \
  | sh -s -- --key "你的KEY" --path "/path/to/ComfyUI"
```

Windows PowerShell：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.ps1))) -ApiKey "你的KEY" -ComfyPath "C:\path\to\ComfyUI"
```

Windows CMD 的参数和 PowerShell 一样，但第 1 步那一行在结束时会把 `install.cmd` 删掉，
所以要把参数写在同一行里：

```batch
curl -fsSL https://raw.githubusercontent.com/snarkify/merak-comfyui-node/main/install.cmd -o install.cmd && install.cmd -ApiKey "你的KEY" && del install.cmd
```

| 参数 | 说明 |
|---|---|
| `--key` / `-ApiKey` | 直接给出 API key，不再提问 |
| `--path` / `-ComfyPath` | 指定 ComfyUI 文件夹，用于自动查找失败时 |
| `--yes` / `-Yes` | 全程不提问；路径缺失或不明确时直接报错退出 |

## 安装 ComfyUI

已经在用 ComfyUI 的可以跳过这一节。

**Windows 或 macOS，最简单的方式是桌面版。** 从
[comfy.org/download](https://www.comfy.org/download) 下载并按提示安装。

**Windows 便携版。** 从[发布页](https://github.com/comfyanonymous/ComfyUI/releases)下载
`ComfyUI_windows_portable_nvidia.7z`，用 [7-Zip](https://www.7-zip.org/) 解压到比如 `C:\` 下面，
然后用 `run_nvidia_gpu.bat` 启动 —— 没有 NVIDIA 显卡就用 `run_cpu.bat`。
两种方式都不影响 Merak，它的渲染本来就在 merak 的 GPU 上跑。

**macOS、Linux 或从源码安装。** 请先查看 ComfyUI 最新的
[安装说明](https://docs.comfy.org/installation/manual_install)。基本步骤是：

```bash
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI
python3 -m venv venv && source venv/bin/activate
pip install -r requirements.txt
python main.py
```

然后在浏览器打开 <http://127.0.0.1:8188>。

## 使用

添加 **video/merak → Merak Generate Video**，填好 prompt，选一个 clip，然后排队执行。
视频会保存到输出目录的 `video/merak_00001_.mp4`，并在节点上直接预览。
改 `filename_prefix` 可以换子目录，或加上 `%date:yyyy-MM-dd%` 这样的占位符。

`team_id` 可以填在节点上，或放进 `MERAK_TEAM_ID` —— 在 merak 控制台的网址里能找到它。

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
| 安装脚本提示找不到 ComfyUI | 用 `--path` / `-ComfyPath` 指定 ComfyUI 文件夹 |
| 装到了错误的那个 ComfyUI | 用 `--path` / `-ComfyPath` 指定，节点会装到你指定的位置 |
| 重启后搜不到 **Merak** 节点 | 确认节点在 `ComfyUI/custom_nodes/merak-comfyui-node` 下，并查看 ComfyUI 控制台里的报错 |
| `403 INFERENCE_NOT_ENABLED` | 你的账号没有开通推理权限 |
| `403` / `404` 且提到 team | 你必须是该 team 的**所有者**，仅是成员不够 |
| `401` | key 缺失或已被吊销 —— 检查 `~/.merak/api_key` 里只有 key 本身 |
| 渲染 `FAILED` 且提示 `input image …` | 关键帧超出尺寸或比例限制 —— 不计费 |
| 轮询超时 | 渲染**没有**被取消 —— 用 *Merak Fetch Video* 重新取回 |

## 许可证

[MIT](LICENSE)。
