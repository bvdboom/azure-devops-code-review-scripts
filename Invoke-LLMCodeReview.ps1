function Invoke-LLMCodeReview {
    param (
        [parameter(Mandatory)]
        [string]
        $SourceBranch,

        [parameter(Mandatory)]
        [string]
        $TargetBranch,

        [Parameter(Mandatory)]
        [string]
        $PathToReviewFile,

        [parameter(Mandatory)]
        [string]
        $ModelName,

        [parameter(Mandatory)]
        [string]
        $ModelDeploymentUrl,

        [parameter(Mandatory)]
        [string]
        $Key
    )

    $schema = @{
        type                 = "object"
        properties           = @{
            reviews = @{
                type  = "array"
                items = @{
                    type                 = "object"
                    properties           = @{
                        fileName   = @{
                            type        = "string"
                            description = "The file path being reviewed"
                        }
                        lineNumber = @{
                            type        = "integer"
                            description = "The line number where the issue occurs"
                        }
                        comment    = @{
                            type        = "string"
                            description = "The review comment with emoji, severity, category, explanation and an optional suggested fix"
                        }
                    }
                    required             = @("fileName", "lineNumber", "comment")
                    additionalProperties = $false
                }
            }
        }
        required             = @("reviews")
        additionalProperties = $false
    }

    [string] $changes = Get-CodeChanges -SourceBranch $SourceBranch -TargetBranch $TargetBranch | Out-String
    Write-Host "Code changes to review:`n$changes"

    # Completion text
    $messages = @()
    $messages += @{
        role    = 'system'
        content = @(
            @{
                type = "text"
                text = Get-Content -Path $PathToReviewFile -Raw
            }
        )
    }
    $messages += @{
        role    = 'user'
        content = @(
            @{
                type = "text"
                text = $changes
            }
        )
    }

    # Header for authentication
    $headers = [ordered]@{
        "Authorization" = "Bearer $($Key)"
    }

    # Adjust these values to fine-tune completions
    $body = [ordered]@{
        model           = $ModelName
        messages        = $messages
        response_format = @{
            type        = "json_schema"
            json_schema = @{
                name   = "CodeReviewResponse" # A required property
                strict = $true # Recommended for structured outputs
                schema = $schema # The JSON schema that defines the expected response structure
            }
        }
    } | ConvertTo-Json -Depth 99

    $response = Invoke-RestMethod `
        -Uri $ModelDeploymentUrl `
        -Headers $headers `
        -Body $body `
        -Method Post `
        -ContentType 'application/json'


    if ($ModelName -eq "model-router") {
        Write-Host "Response from $ModelName using $($response.model):"
    } else {
        Write-Host "Response from $($ModelName):"
    }

    return $response.choices.message.content
}
