# download-deps.ps1
# Downloads required dependencies for azooKey-Windows build

$ErrorActionPreference = "Stop"

function Download-Extract {
    param (
        [string]$url,
        [string]$destFolder
    )
    Write-Host "Downloading $url ..." -ForegroundColor Cyan
    $tempZip = Join-Path $env:TEMP "llama_temp.zip"
    Invoke-WebRequest -Uri $url -OutFile $tempZip
    New-Item -Path $destFolder -ItemType Directory -Force | Out-Null
    Expand-Archive -Path $tempZip -DestinationPath $destFolder -Force
    Remove-Item $tempZip
    Write-Host "Extracted to $destFolder" -ForegroundColor Green
}

# Create directories
$llamaCpuDir = "llama_cpu"
$llamaCudaDir = "llama_cuda"
$llamaVulkanDir = "llama_vulkan"

Write-Host "=== Downloading llama.cpp binaries ===" -ForegroundColor Yellow

# Download and extract llama binaries
Download-Extract -url "https://github.com/fkunn1326/llama.cpp/releases/download/b4846/llama-b4846-bin-win-avx-x64.zip" -destFolder $llamaCpuDir
Download-Extract -url "https://github.com/fkunn1326/llama.cpp/releases/download/b4846/llama-b4846-bin-win-cuda-cu12.4-x64.zip" -destFolder $llamaCudaDir
Download-Extract -url "https://github.com/fkunn1326/llama.cpp/releases/download/b4846/llama-b4846-bin-win-vulkan-x64.zip" -destFolder $llamaVulkanDir

# Copy llama.lib to server-swift
Write-Host "=== Copying llama.lib to server-swift ===" -ForegroundColor Yellow
Copy-Item "$llamaCpuDir\llama.lib" -Destination "server-swift\" -Force
Write-Host "Copied llama.lib to server-swift/" -ForegroundColor Green

# Download zenz model
Write-Host "=== Downloading zenz.gguf model (this may take a while) ===" -ForegroundColor Yellow
$zenzUrl = "https://huggingface.co/Miwa-Keita/zenz-v3-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf"
$zenzDest = "zenz.gguf"
Invoke-WebRequest -Uri $zenzUrl -OutFile $zenzDest
Write-Host "Downloaded zenz.gguf" -ForegroundColor Green

Write-Host ""
Write-Host "=== All dependencies downloaded successfully! ===" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Apply Swift SDK fix (if not done):"
Write-Host '     $SwiftPath = "$env:LOCALAPPDATA\Programs\Swift\Platforms\*\Windows.platform\Developer\SDKs\Windows.sdk\usr"'
Write-Host '     Invoke-WebRequest -Uri "https://gist.githubusercontent.com/fkunn1326/ef8be2217082302b291f2b8d4178194a/raw/c424968c250afcd5afa1131aea1329dc0744a7f9/ucrt.modulemap" -OutFile "$SwiftPath\share\ucrt.modulemap"'
Write-Host ""
Write-Host "  2. Run the build:"
Write-Host "     cargo make build --release"
