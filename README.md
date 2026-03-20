# Azure OpenClaw 一键安装说明

这个目录里的 `azure-openclaw-oneclick.sh` 是一个用于 Azure Cloud Shell 的一键安装脚本，用来快速创建一台运行 OpenClaw 的 Azure VM，并完成基础环境准备。

## 脚本会做什么

脚本默认会完成以下事情：

1. 选择当前 Azure 订阅，或者让你交互式选择订阅。
2. 创建资源组。
3. 创建网络资源，包括 VNet、Subnet、NSG、NIC 和公网 IP。
4. 放通入站 `5566` 端口，并把 VM 内的 `5566` 转发到 `22`，方便通过 `ssh -p 5566` 登录。
5. 优先复用本地已有的 SSH key pair；如果只找到私钥会自动补生成公钥；如果完全没有可复用的 key pair，才会创建新的 `ed25519` key pair。
6. 创建 Azure AI Services 资源，默认区域是 `eastus2`。
7. 创建 Ubuntu 24.04 LTS 虚拟机，默认规格是 `Standard_D2as_v6`。
8. 给 VM 分配 Managed Identity，并授予访问 Azure AI 资源所需的角色。
9. 通过 cloud-init 在 VM 中安装 Docker。
10. 生成 LiteLLM 配置，并以 Docker 容器方式启动 LiteLLM。
11. 创建 `litellm` systemd 服务，确保机器重启后 LiteLLM 还能自动拉起。
12. 安装 Homebrew 和 `gcc`。
13. 使用 OpenClaw 官方安装脚本安装 OpenClaw。
14. 生成统一的环境变量文件，路径是 `/home/openclaw/.openclaw/gateway.env`。
15. 生成 OpenClaw 配置文件和 LiteLLM 配置文件。
16. 输出最终登录信息、IP、SSH 命令和 VM 内的关键文件位置。

## 当前脚本的边界

下面这些事情当前脚本不会自动完成：

1. 不会自动创建 Azure AI Foundry 的模型 deployment。
2. 默认只配置两个模型路由：`gpt-5.4` 和 `gpt-5.3-codex`。
3. 不会把 OpenClaw 本身注册成 systemd 服务。

所以在脚本执行完以后，你通常还需要去 Azure AI Foundry Portal 手动创建这两个 deployment。

## 如何使用

### 方式一：直接使用默认值

在 Azure Cloud Shell 中运行：

```bash
bash azure-openclaw-oneclick.sh
```

脚本会提示你：

1. 选择订阅。
2. 输入资源组名称，直接回车则使用默认值。

执行完成后会输出：

1. 资源组名称。
2. VM 名称。
3. Azure AI 资源名称。
4. 公网 IP。
5. SSH 登录命令。

### 方式二：通过环境变量覆盖默认值

你可以在运行前先设置环境变量：

```bash
export SUBSCRIPTION_ID="<your-subscription-id>"
export RG_NAME="rg-openclaw-demo"
export VM_LOCATION="southeastasia"
export AI_LOCATION="eastus2"
export SSH_PUBLIC_KEY_PATH="$HOME/.ssh/id_ed25519.pub"
export MODEL_DEPLOYMENT_GPT54="gpt-5.4"
export MODEL_DEPLOYMENT_GPT53_CODEX="gpt-5.3-codex"

bash azure-openclaw-oneclick.sh
```

如果不设置 `SSH_PUBLIC_KEY_PATH`，脚本会优先按下面顺序复用本地已有 key pair：

1. `SSH_PUBLIC_KEY_PATH` 对应的 key pair。
2. `~/.ssh/id_ed25519`
3. `~/.ssh/id_ecdsa`
4. `~/.ssh/id_rsa`

如果某个私钥存在但对应公钥缺失，脚本会自动补生成 `.pub` 文件；如果上述位置都没有可复用的 key pair，才会新建一个新的 `ed25519` key pair。

## 常用默认值

当前脚本里的主要默认值：

1. VM 区域：`southeastasia`
2. Azure AI 区域：`eastus2`
3. VM 规格：`Standard_D2as_v6`
4. VM 镜像：`Canonical:ubuntu-24_04-lts:server:latest`
5. SSH 端口：`5566`
6. LiteLLM 端口：`4000`
7. OpenClaw Gateway 端口：`18789`

## 安装完成后怎么登录

脚本结束后会打印类似下面的命令：

```bash
ssh -p 5566 openclaw@<public-ip>
```

登录到 VM 后，建议先执行：

```bash
source ~/.openclaw/gateway.env
systemctl status litellm --no-pager
docker ps --filter name=litellm
```

## 关键文件位置

在 VM 中，常用文件如下：

1. 环境变量文件：`/home/openclaw/.openclaw/gateway.env`
2. OpenClaw 配置：`/home/openclaw/.openclaw/openclaw.json`
3. LiteLLM 配置：`/home/openclaw/.openclaw/litellm-config.yaml`
4. 安装摘要：`/home/openclaw/openclaw-ready.txt`
5. bootstrap 日志：`/var/log/openclaw-bootstrap.log`

## 快速排查

如果你想确认 LiteLLM 是否正常启动，可以执行：

```bash
source ~/.openclaw/gateway.env
systemctl status litellm --no-pager
docker logs --tail 100 litellm
curl -H "Authorization: Bearer $LITELLM_API_KEY" http://127.0.0.1:4000/v1/models
```

如果 LiteLLM 容器在，但调用 Azure 模型失败，通常优先检查这几项：

1. Azure AI Foundry deployment 是否已经手动创建。
2. VM 的 Managed Identity 角色是否已经生效。
3. `gateway.env` 中的 Azure 相关变量是否存在。
