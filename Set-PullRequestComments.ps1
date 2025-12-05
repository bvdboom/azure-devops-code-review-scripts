function Set-PullRequestComments {
    param (
        [parameter(Mandatory)]
        [string]
        $Organization,

        [parameter(Mandatory)]
        [int]
        $PullRequestId,

        [Parameter(Mandatory)]
        [string]
        $RepositoryName,

        [parameter(Mandatory)]
        [string]
        $Project,

        [parameter(Mandatory)]
        [string]
        $Reviews,

        [parameter()]
        [switch]
        $AutoApprove
    )

    $token = (New-Object System.Management.Automation.PSCredential("token", (Get-AzAccessToken -ResourceUrl "499b84ac-1321-427f-aa17-267ca6975798" -AsSecureString).token)).GetNetworkCredential().Password
    $headers = @{
        Authorization  = "Bearer $token"
        "Content-Type" = "application/json"
    }

    # Get current authenticated user from Azure DevOps
    $connectionData = Invoke-RestMethod -Uri "https://dev.azure.com/$Organization/_apis/connectionData" -Headers $headers -Method Get
    $currentUserName = $connectionData.authenticatedUser.providerDisplayName
    Write-Host "Checking for existing comments from: $currentUserName"

    # Get existing threads
    $getThreadsUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/threads?api-version=7.1"

    try {
        $existingThreads = Invoke-RestMethod -Uri $getThreadsUrl -Headers $headers -Method Get
    }
    catch {
        Write-Warning "Failed to retrieve existing threads, continuing without duplicate check..."
        $existingThreads = $null
    }

    # Build a lookup hashtable of existing comments by file:line
    $existingComments = @{}
    if ($existingThreads) {
        foreach ($thread in $existingThreads.value) {
            # Skip deleted threads or threads without context
            if ($thread.isDeleted -or -not $thread.threadContext -or -not $thread.threadContext.filePath) {
                continue
            }

            if ($thread.status -notin @("active", "pending", "fixed", "wontFix", "closed")) {
                continue
            }

            # Check if any comment is from the current user (not deleted)
            $hasUserComment = $thread.comments | Where-Object {
                $_.author.displayName -eq $currentUserName 
            } | Select-Object -First 1

            if ($hasUserComment) {
                # Normalize file path (lowercase, ensure leading /)
                $normalizedPath = $thread.threadContext.filePath.ToLower()
                if (-not $normalizedPath.StartsWith('/')) {
                    $normalizedPath = "/$normalizedPath"
                }
                $key = "$normalizedPath|$($thread.threadContext.rightFileStart.line)"
                $existingComments[$key] = $true
            }
        }
    }

    # Parse and validate reviews
    $reviewsObject = $Reviews | ConvertFrom-Json
    if ($null -eq $reviewsObject.reviews -or $reviewsObject.reviews.Count -eq 0) {
        Write-Host "No reviews to post."
        
        if ($AutoApprove) {
            Write-Host "AutoApprove enabled: Approving pull request..." -ForegroundColor Cyan
            $reviewerId = $connectionData.authenticatedUser.id
            $approveUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/reviewers/$($reviewerId)?api-version=7.1"
            
            $approveBody = @{
                vote = 10
            }
            
            try {
                # Use PUT to add/update reviewer with vote (works whether reviewer exists or not)
                $null = Invoke-RestMethod -Uri $approveUrl -Headers $headers -Method Put -Body ($approveBody | ConvertTo-Json -Depth 10)
                Write-Host "Pull request approved successfully." -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to approve pull request: $_"
            }
        }
        
        return
    }

    # Filter out duplicate reviews
    $newReviews = $reviewsObject.reviews | Where-Object {
        # Normalize file path
        $normalizedPath = $_.fileName.ToLower()
        if (-not $normalizedPath.StartsWith('/')) {
            $normalizedPath = "/$normalizedPath"
        }
        $key = "$normalizedPath|$($_.lineNumber)"

        # Keep only reviews that don't exist yet
        -not $existingComments.ContainsKey($key)
    }

    if ($newReviews.Count -eq 0) {
        Write-Host "All comments already exist. No new comments to post." -ForegroundColor Yellow
        return
    }

    $skipped = $reviewsObject.reviews.Count - $newReviews.Count
    if ($skipped -gt 0) {
        Write-Host "Skipping $skipped duplicate comment(s)" -ForegroundColor Yellow
    }

    # Post new reviews
    $createThreadUrl = "https://dev.azure.com/$Organization/$Project/_apis/git/repositories/$RepositoryName/pullRequests/$PullRequestId/threads?api-version=7.1"

    foreach ($review in $newReviews) {
        # Determine line range for suggestions
        $startLine = $review.lineNumber
        $endLine = $review.lineNumber
        $endOffset = 1000

        $threadBody = @{
            comments      = @(
                @{
                    parentCommentId = 0
                    content         = $review.comment
                    commentType     = 1
                }
            )
            status        = 1
            threadContext = @{
                filePath       = $review.fileName
                rightFileStart = @{ line = $startLine; offset = 1 }
                rightFileEnd   = @{ line = $endLine; offset = $endOffset }
            }
        }

        try {
            $response = Invoke-RestMethod -Uri $createThreadUrl -Headers $headers -Method Post -Body ($threadBody | ConvertTo-Json -Depth 10)
            Write-Host "Comment posted on '$($review.fileName)' line $($review.lineNumber) (Thread ID: $($response.id))" -ForegroundColor Green
        }
        catch {
            Write-Warning "Failed to post comment on '$($review.fileName)' line $($review.lineNumber): $_"
        }
    }
}
