# Jenkins Configuration
$jenkinsUrl = "http://YOUR_JENKINS_URL"
$username = "your_username"
$password = "your_password"

# Create credential
$pair = "$($username):$($password)"
$encodedCreds = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($pair))
$headers = @{
    Authorization = "Basic $encodedCreds"
}

# Function to safely extract text from XML nodes
function Get-XmlNodeText {
    param($node)
    if ($node -and $node.'#text') {
        return $node.'#text'
    } elseif ($node) {
        return $node.ToString()
    }
    return ""
}

# Get all jobs
Write-Host "Fetching all Jenkins jobs..." -ForegroundColor Green
$jobsUrl = "$jenkinsUrl/api/json?tree=jobs[name,url,color]"
$response = Invoke-RestMethod -Uri $jobsUrl -Headers $headers -Method Get

$allJobs = $response.jobs
Write-Host "Found $($allJobs.Count) jobs" -ForegroundColor Yellow

# Prepare result array
$jobDetails = @()
$counter = 0

foreach ($job in $allJobs) {
    $counter++
    Write-Host "[$counter/$($allJobs.Count)] Processing: $($job.name)" -ForegroundColor Cyan
    
    try {
        # Get job config XML
        $configUrl = "$jenkinsUrl/job/$($job.name)/config.xml"
        $config = Invoke-RestMethod -Uri $configUrl -Headers $headers -Method Get
        
        # Parse XML
        [xml]$xmlConfig = $config
        
        # Determine job type
        $jobType = $xmlConfig.DocumentElement.LocalName
        
        # Extract Git URLs (can be multiple)
        $gitUrls = @()
        $gitBranches = @()
        
        if ($xmlConfig.project.scm.userRemoteConfigs) {
            $xmlConfig.project.scm.userRemoteConfigs.ChildNodes | ForEach-Object {
                if ($_.url) {
                    $gitUrls += Get-XmlNodeText $_.url
                }
            }
        }
        
        if ($xmlConfig.project.scm.branches) {
            $xmlConfig.project.scm.branches.ChildNodes | ForEach-Object {
                if ($_.name) {
                    $gitBranches += Get-XmlNodeText $_.name
                }
            }
        }
        
        # Extract parameters with defaults
        $paramsList = @()
        if ($xmlConfig.project.properties.'hudson.model.ParametersDefinitionProperty'.parameterDefinitions) {
            $xmlConfig.project.properties.'hudson.model.ParametersDefinitionProperty'.parameterDefinitions.ChildNodes | ForEach-Object {
                $paramName = Get-XmlNodeText $_.name
                $paramDefault = Get-XmlNodeText $_.defaultValue
                $paramType = $_.LocalName
                if ($paramName) {
                    $paramsList += "${paramType}:${paramName}=$(if($paramDefault){$paramDefault}else{''})"
                }
            }
        }
        
        # Extract build steps details
        $buildStepsList = @()
        if ($xmlConfig.project.builders) {
            $xmlConfig.project.builders.ChildNodes | ForEach-Object {
                $stepType = $_.LocalName
                $buildStepsList += $stepType
            }
        }
        
        # Extract shell/batch commands
        $allCommands = @()
        
        # Shell commands (Linux)
        if ($xmlConfig.project.builders.'hudson.tasks.Shell') {
            $xmlConfig.project.builders.'hudson.tasks.Shell' | ForEach-Object {
                $cmd = Get-XmlNodeText $_.command
                if ($cmd) {
                    $allCommands += "SHELL: " + $cmd.Trim()
                }
            }
        }
        
        # Batch commands (Windows)
        if ($xmlConfig.project.builders.'hudson.tasks.BatchFile') {
            $xmlConfig.project.builders.'hudson.tasks.BatchFile' | ForEach-Object {
                $cmd = Get-XmlNodeText $_.command
                if ($cmd) {
                    $allCommands += "BATCH: " + $cmd.Trim()
                }
            }
        }
        
        # PowerShell commands
        if ($xmlConfig.project.builders.'hudson.plugins.powershell.PowerShell') {
            $xmlConfig.project.builders.'hudson.plugins.powershell.PowerShell' | ForEach-Object {
                $cmd = Get-XmlNodeText $_.command
                if ($cmd) {
                    $allCommands += "POWERSHELL: " + $cmd.Trim()
                }
            }
        }
        
        # Maven goals
        $mavenGoals = ""
        if ($xmlConfig.project.builders.'hudson.tasks.Maven') {
            $mavenGoals = Get-XmlNodeText $xmlConfig.project.builders.'hudson.tasks.Maven'.targets
        }
        
        # Extract triggers
        $triggersList = @()
        $cronSchedule = ""
        
        if ($xmlConfig.project.triggers) {
            $xmlConfig.project.triggers.ChildNodes | ForEach-Object {
                $triggerType = $_.LocalName
                $triggersList += $triggerType
                
                # Get cron schedule if exists
                if ($_.spec) {
                    $cronSchedule = Get-XmlNodeText $_.spec
                }
            }
        }
        
        # Extract post-build actions
        $postBuildList = @()
        if ($xmlConfig.project.publishers) {
            $xmlConfig.project.publishers.ChildNodes | ForEach-Object {
                $postBuildList += $_.LocalName
            }
        }
        
        # Create comprehensive hash for similarity detection (excluding job name)
        $configString = "$($gitUrls -join '|')|$($gitBranches -join '|')|$($buildStepsList -join '|')|$($allCommands -join '|')|$mavenGoals|$($triggersList -join '|')|$cronSchedule"
        $configBytes = [System.Text.Encoding]::UTF8.GetBytes($configString)
        $configHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($configBytes)) -Algorithm MD5).Hash
        
        # Build the job info object
        $jobInfo = [PSCustomObject]@{
            JobName = $job.name
            JobType = $jobType
            JobURL = $job.url
            Status = $job.color
            Disabled = if ($xmlConfig.project.disabled) { $xmlConfig.project.disabled } else { "false" }
            Description = (Get-XmlNodeText $xmlConfig.project.description) -replace "`n"," " -replace "`r"," "
            
            # Git Information
            Git_URLs = $gitUrls -join " | "
            Git_Branches = $gitBranches -join " | "
            
            # SCM Type
            SCM_Type = if ($xmlConfig.project.scm.class) { $xmlConfig.project.scm.class } else { "None" }
            
            # Build Triggers
            Triggers = $triggersList -join " | "
            Cron_Schedule = $cronSchedule
            
            # Parameters
            Parameters = $paramsList -join " | "
            Parameter_Count = $paramsList.Count
            
            # Build Steps
            Build_Steps = $buildStepsList -join " | "
            Build_Steps_Count = $buildStepsList.Count
            
            # Commands/Scripts
            Commands_Full = ($allCommands -join " ### ") -replace "`n"," " -replace "`r"," "
            Commands_Summary = if ($allCommands) { 
                ($allCommands -join " ### ").Substring(0, [Math]::Min(500, ($allCommands -join " ### ").Length)) 
            } else { "" }
            
            # Maven
            Maven_Goals = $mavenGoals
            
            # Post Build Actions
            Post_Build_Actions = $postBuildList -join " | "
            
            # Node/Label
            Assigned_Node = if ($xmlConfig.project.assignedNode) { Get-XmlNodeText $xmlConfig.project.assignedNode } else { "any" }
            Restrict_Node = if ($xmlConfig.project.canRoam) { $xmlConfig.project.canRoam } else { "false" }
            
            # JDK
            JDK = if ($xmlConfig.project.jdk) { Get-XmlNodeText $xmlConfig.project.jdk } else { "" }
            
            # Workspace
            Custom_Workspace = if ($xmlConfig.project.customWorkspace) { Get-XmlNodeText $xmlConfig.project.customWorkspace } else { "" }
            
            # Configuration Hash (for duplicate detection)
            Config_Hash = $configHash
        }
        
        $jobDetails += $jobInfo
        
    } catch {
        Write-Host "Error processing $($job.name): $_" -ForegroundColor Red
        # Add error entry
        $jobDetails += [PSCustomObject]@{
            JobName = $job.name
            JobType = "ERROR"
            JobURL = $job.url
            Status = "ERROR"
            Description = "Failed to process: $_"
        }
    }
}

# Export to CSV
$outputFile = "jenkins_jobs_export_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$jobDetails | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

Write-Host "`nExport completed!" -ForegroundColor Green
Write-Host "Output file: $outputFile" -ForegroundColor Yellow
Write-Host "Total jobs exported: $($jobDetails.Count)" -ForegroundColor Yellow

# Show summary statistics
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
$duplicateHashes = $jobDetails | Group-Object Config_Hash | Where-Object { $_.Count -gt 1 }
Write-Host "Potential duplicate groups (same config hash): $($duplicateHashes.Count)" -ForegroundColor Yellow

if ($duplicateHashes.Count -gt 0) {
    Write-Host "`nDuplicate groups found:" -ForegroundColor Yellow
    foreach ($group in $duplicateHashes) {
        Write-Host "  - $($group.Count) jobs: $($group.Group.JobName -join ', ')" -ForegroundColor White
    }
}

Write-Host "`nUpload the CSV file to AI for detailed duplicate analysis!" -ForegroundColor Green
