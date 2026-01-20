# Requires -Version 5.1

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 1. Strict System Prompt Check
$sysPromptPath = Join-Path $PSScriptRoot "sysprompt.md"
if (-not (Test-Path $sysPromptPath)) {
    Write-Host "Error: 'sysprompt.md' not found. This file is required." -ForegroundColor Red
    exit 1
}
$sysInstructionText = Get-Content $sysPromptPath -Raw -Encoding UTF8

# 2. API Key Input (Masked, User Input Only)
$apiKey = Read-Host "Enter your Gemini API key" -MaskInput

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    Write-Host "Error: API key cannot be empty." -ForegroundColor Red
    exit 1
}

# 3. Model Selection
$availableModels = @(
    "gemini-3-flash-preview",
    "gemini-3-pro-preview",
    "gemini-2.5-flash",
    "gemini-2.5-flash-lite",
    "gemini-2.5-pro"
)

Write-Host "`nSelect a model:" -ForegroundColor Cyan
for ($i = 0; $i -lt $availableModels.Count; $i++) {
    Write-Host "[$($i + 1)] $($availableModels[$i])"
}
Write-Host "[Enter] Default (gemini-3-flash-preview)" -ForegroundColor Gray

$selection = Read-Host "`nEnter choice (number or name)"

$defaultModel = "gemini-3-flash-preview"
$targetModel = $defaultModel

if (-not [string]::IsNullOrWhiteSpace($selection)) {
    if ($selection -match "^\d+$" -and [int]$selection -ge 1 -and [int]$selection -le $availableModels.Count) {
        $targetModel = $availableModels[[int]$selection - 1]
    }
    elseif ($availableModels -contains $selection) {
        $targetModel = $selection
    }
    else {
        # Check for forbidden models
        if ($selection -match "gemini-2\.0") {
            Write-Warning "Gemini 2.0 models are not allowed. Using default."
        }
        else {
            $targetModel = $selection
        }
    }
}

Write-Host "Using model: $targetModel" -ForegroundColor Green

# 4. User Inputs
$userPrompt = Read-Host "Enter your question"
$imagePath = Read-Host "Enter image path (optional)"

# 5. API Call Function
function Invoke-Gemini {
    param (
        [string]$Model,
        [string]$PromptText,
        [string]$ImgPath,
        [string]$SysPrompt,
        [string]$Key
    )

    $apiUrl = "https://generativelanguage.googleapis.com/v1beta/models/${Model}:generateContent"

    # System Instruction
    $payload = @{
        "systemInstruction" = @{
            "role"  = "system"
            "parts" = @(
                @{ "text" = $SysPrompt }
            )
        }
        "generationConfig"  = @{
            
        }
    }

    # User Content & Image
    $userParts = @(
        @{ "text" = $PromptText }
    )

    if (-not [string]::IsNullOrWhiteSpace($ImgPath)) {
        $ImgPath = $ImgPath -replace '"', ''
        if (Test-Path $ImgPath) {
            $imgBytes = [System.IO.File]::ReadAllBytes($ImgPath)
            $base64 = [Convert]::ToBase64String($imgBytes)
            
            $ext = [System.IO.Path]::GetExtension($ImgPath).ToLower()
            $mimeType = switch ($ext) {
                ".png" { "image/png" }
                ".jpg" { "image/jpeg" }
                ".jpeg" { "image/jpeg" }
                ".webp" { "image/webp" }
                ".heic" { "image/heic" }
                ".heif" { "image/heif" }
                Default { "image/jpeg" }
            }

            $userParts += @{
                "inline_data" = @{
                    "mime_type" = $mimeType
                    "data"      = $base64
                }
            }
        }
        else {
            Write-Warning "Image not found at '$ImgPath'. Ignoring."
        }
    }

    $payload["contents"] = @(
        @{
            "role"  = "user"
            "parts" = $userParts
        }
    )

    $jsonBody = $payload | ConvertTo-Json -Depth 10 -Compress

    try {
        $response = Invoke-RestMethod -Uri $apiUrl `
            -Method Post `
            -Body $jsonBody `
            -ContentType "application/json" `
            -Headers @{ "x-goog-api-key" = $Key } `
            -ErrorAction Stop
        
        return $response
    }
    catch {
        Write-Host "`nAPI Request Failed for model '$Model'!" -ForegroundColor Red
        if ($_.Exception.Response) {
            $stream = $_.Exception.Response.GetResponseStream()
            if ($stream) {
                $reader = New-Object System.IO.StreamReader($stream)
                $errDetails = $reader.ReadToEnd()
                Write-Host $errDetails -ForegroundColor Red
            }
        }
        else {
            Write-Host $_.Exception.Message -ForegroundColor Red
        }
        throw $_
    }
}

# 6. Execution Logic with Retry
try {
    Write-Host "`nSending request..." -ForegroundColor Cyan
    $result = Invoke-Gemini -Model $targetModel -PromptText $userPrompt -ImgPath $imagePath -SysPrompt $sysInstructionText -Key $apiKey
}
catch {
    # If the initial request fails and we aren't already using the default, ask to retry
    if ($targetModel -ne $defaultModel) {
        Write-Host ""
        $confirm = Read-Host "Model '$targetModel' failed. Retry with default '$defaultModel'? (y/n)"
        if ($confirm -eq 'y') {
            try {
                Write-Host "Retrying with $defaultModel..." -ForegroundColor Cyan
                $result = Invoke-Gemini -Model $defaultModel -PromptText $userPrompt -ImgPath $imagePath -SysPrompt $sysInstructionText -Key $apiKey
            }
            catch {
                Write-Host "Fatal Error with default model. Exiting." -ForegroundColor Red
                exit 1
            }
        }
        else {
            exit 1
        }
    }
    else {
        # Already failed on default or user chose not to retry
        exit 1
    }
}

# 7. Output Handling
if ($result -and $result.candidates -and $result.candidates.content) {
    $responseText = $result.candidates.content.parts.text -join "`n"
    
    $outputFile = Join-Path $PSScriptRoot "result.md"
    $responseText | Out-File -FilePath $outputFile -Encoding UTF8
    
    Write-Host "Success! Saved to result.md" -ForegroundColor Green
    Start-Process "notepad.exe" -ArgumentList $outputFile
}
else {
    Write-Host "No text content returned." -ForegroundColor Yellow
    if ($result) {
        Write-Host ($result | ConvertTo-Json -Depth 5)
    }
}
