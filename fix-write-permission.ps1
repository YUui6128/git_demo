<#
.SYNOPSIS
    修复 Windows 下 "EPERM: operation not permitted" / "Access is denied" 导致写不进文件的问题。

.DESCRIPTION
    VS Code / Node.js / 各种编辑器保存文件时报 EPERM，绝大多数情况是下面两件事凑在一起：
      1) 你虽然是管理员，但程序以【非提升】令牌运行，UAC 把 Administrators 组过滤掉了
         （whoami /groups 里显示 "Group used for deny only"）；
      2) 目标目录的 ACL 只给 Users / Authenticated Users 读取和执行 (RX)，根本没有写权限。

    本脚本会：
      [1] 诊断：打印当前账号、有效管理员令牌、目录 ACL、真实可写性；
      [2] 修复：通过一次 UAC 提权，给指定账号加上 (OI)(CI)M（修改 + 向下继承）；
      [3] 验证：重新测试写入并打印新的 ACL。

    脚本自身会检测到"没提权 + 不可写"时自动重新以管理员身份启动，所以
    你不需要手动去开管理员 PowerShell。

.PARAMETER Path
    要修复的目录。默认是当前所在目录。

.PARAMETER User
    要授权的账号，默认当前登录用户（域\用户名）。

.PARAMETER Elevated
    内部参数，标记"当前已是提权后的子进程"，请不要手动传。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\fix-write-permission.ps1 -Path "D:\git_demo"

.EXAMPLE
    # 修当前目录
    powershell -ExecutionPolicy Bypass -File .\fix-write-permission.ps1

.NOTES
    需要管理员权限，会弹 UAC 让你点"是"。
    若当前是标准账户，UAC 会要求输入管理员账号密码。
    不会碰 WindowsApps / Program Files / System Volume Information 这类系统保护目录。
#>
[CmdletBinding()]
param(
    [string]$Path = (Get-Location).Path,
    [string]$User = "$env:USERDOMAIN\$env:USERNAME",
    [switch]$Elevated
)

$ErrorActionPreference = 'Stop'
$LogFile = Join-Path $env:TEMP 'fix-write-permission.log'

# ---------------------------------------------------------------- 工具函数

function Test-Writable {
    param([string]$Dir)
    if (-not (Test-Path -LiteralPath $Dir)) { return $false }
    $tmp = Join-Path $Dir ('__wtest_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        Set-Content -LiteralPath $tmp -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        return $true
    } catch {
        return $false
    }
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-AdminGroupState {
    # 显示 Administrators 组是 "Enabled group" 还是 "Group used for deny only"
    $line = whoami /groups | Select-String -Pattern 'S-1-5-32-544' | Select-Object -First 1
    if ($null -eq $line) { return '(不在 Administrators 组)' }
    $t = $line.ToString()
    if ($t -match 'deny only|只用于拒绝') { return 'Group used for deny only  <- UAC 已过滤，当前不是有效管理员' }
    return 'Enabled group  <- 当前是有效管理员'
}

function Show-Diagnosis {
    param([string]$Dir)

    Write-Host ''
    Write-Host '================ 诊断 ================' -ForegroundColor Cyan
    Write-Host ("目标目录        : {0}" -f $Dir)
    Write-Host ("当前账号        : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-Host ("授权目标账号    : {0}" -f $User)
    Write-Host ("Administrators  : {0}" -f (Get-AdminGroupState))

    $elev = Test-IsElevated
    Write-Host ("有效管理员令牌  : {0}" -f $elev)

    $writable = Test-Writable $Dir
    if ($writable) {
        Write-Host '当前可写        : True' -ForegroundColor Green
    } else {
        Write-Host '当前可写        : False   <-- 这就是 EPERM 的直接原因' -ForegroundColor Red
    }

    Write-Host ''
    Write-Host '--- 当前 ACL ---' -ForegroundColor Cyan
    # 必须 Out-Host：否则 icacls 输出会混进调用方的变量，把布尔值变成数组
    icacls $Dir | Out-Host

    $acl = Get-Acl -LiteralPath $Dir
    Write-Host ''
    Write-Host ("所有者            : {0}" -f $acl.Owner)
    Write-Host ("继承是否被关闭    : {0}" -f $acl.AreAccessRulesProtected)
}

function Show-Verdict {
    param([string]$Dir)
    Write-Host ''
    Write-Host '================ 结果 ================' -ForegroundColor Cyan
    if (Test-Writable $Dir) {
        Write-Host ("[成功] {0} 现在可以写入了。" -f $Dir) -ForegroundColor Green
        Write-Host '       回到编辑器直接点"重试"即可；若仍失败，重启一次编辑器。'
        Write-Host ''
        Write-Host '--- 新的 ACL ---' -ForegroundColor Cyan
        icacls $Dir
    } else {
        Write-Host ("[失败] {0} 仍然不可写。" -f $Dir) -ForegroundColor Red
        Write-Host '       可能原因：'
        Write-Host '         * 目录 ACL 继承被关闭且带 Deny 规则  -> 需要处理所有者/Deny 条目'
        Write-Host '         * 目录被其他进程独占锁定             -> 先关掉占用它的程序'
        Write-Host '         * 磁盘/分区被设为只读                -> diskpart: attributes disk clear readonly'
        Write-Host '         * Windows 安全中心的"受控文件夹访问" -> 在勒索软件防护里放行'
    }
}

# ---------------------------------------------------------------- 主流程

$Path = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path

# --- 分支 A：这是提权后的子进程，只做修复动作，然后把输出写进日志
if ($Elevated) {
    $out = @()
    $out += "target : $Path"
    $out += "grant  : ${User}:(OI)(CI)M"
    $out += '----------------------------------------'
    $out += (icacls $Path /grant "${User}:(OI)(CI)M" 2>&1 | Out-String)
    $out | Set-Content -LiteralPath $LogFile -Encoding UTF8
    exit 0
}

# --- 分支 B：普通进程，先诊断
Show-Diagnosis -Dir $Path
$writable = Test-Writable $Path

if ($writable) {
    Write-Host ''
    Write-Host '[跳过] 该目录本来就可写，无需修改权限。' -ForegroundColor Green
    exit 0
}

if (-not $PSCommandPath) {
    Write-Host ''
    Write-Host '[错误] 请先把脚本保存为 .ps1 文件再运行，否则无法自动提权。' -ForegroundColor Red
    Write-Host '       手动方案：开一个管理员 PowerShell，执行'
    Write-Host ("       icacls `"{0}`" /grant `"{1}:(OI)(CI)M`"" -f $Path, $User)
    exit 1
}

Write-Host ''
Write-Host '需要管理员权限来修改 ACL，正在请求 UAC 提权（请在弹出的窗口点"是"）...' -ForegroundColor Yellow

Remove-Item -LiteralPath $LogFile -Force -ErrorAction SilentlyContinue

$argList = @(
    '-NoProfile'
    '-ExecutionPolicy', 'Bypass'
    '-File', ('"{0}"' -f $PSCommandPath)
    '-Path', ('"{0}"' -f $Path)
    '-User', ('"{0}"' -f $User)
    '-Elevated'
)

try {
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
    Write-Host ("提权进程退出码: {0}" -f $proc.ExitCode)
} catch {
    Write-Host ''
    Write-Host ("[已取消] 提权未完成：{0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host '         手动方案：开一个管理员 PowerShell，执行'
    Write-Host ("         icacls `"{0}`" /grant `"{1}:(OI)(CI)M`"" -f $Path, $User)
    exit 1
}

if (Test-Path -LiteralPath $LogFile) {
    Write-Host ''
    Write-Host '--- 提权进程输出 ---' -ForegroundColor Cyan
    Get-Content -LiteralPath $LogFile
}

Show-Verdict -Dir $Path
