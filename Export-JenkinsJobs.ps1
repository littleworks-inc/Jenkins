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

# Function to fix XML 1.1 version to 1.0 for PowerShell parsing
function Fix-XmlVersion {
    param([string]$xmlContent)
    # Replace XML 1.1 with 1.0
    return $xmlContent -replace "<?xml version='1.1'", "<?xml version='1.0'"
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
        $configRaw = Invoke-RestMethod -Uri $configUrl -Headers $headers -Method Get
        
        # Fix XML version issue
        $config = Fix-XmlVersion -xmlContent $configRaw
        
        # Parse XML
        [xml]$xmlConfig = $config
        
        # Determine job type
        $jobType = $xmlConfig.DocumentElement.LocalName
        
        # Extract Git URLs (can be multiple)
        $gitUrls = @()
        $gitBranches = @()
        $gitCredentials = @()
        
        if ($xmlConfig.project.scm.userRemoteConfigs) {
            $xmlConfig.project.scm.userRemoteConfigs.ChildNodes | ForEach-Object {
                if ($_.url) {
                    $gitUrls += Get-XmlNodeText $_.url
                }
                if ($_.credentialsId) {
                    $gitCredentials += Get-XmlNodeText $_.credentialsId
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
                $paramType = $_.LocalName -replace 'hudson\.model\.', '' -replace 'ParameterDefinition', ''
                if ($paramName) {
                    $paramsList += "${paramType}:${paramName}=$(if($paramDefault){$paramDefault}else{'N/A'})"
                }
            }
        }
        
        # Extract build steps details
        $buildStepsList = @()
        if ($xmlConfig.project.builders) {
            $xmlConfig.project.builders.ChildNodes | ForEach-Object {
                $stepType = $_.LocalName -replace 'hudson\.tasks\.', ''
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
                $triggerType = $_.LocalName -replace 'hudson\.triggers\.', ''
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
                $actionType = $_.LocalName -replace 'hudson\.tasks\.', ''
                $postBuildList += $actionType
            }
        }
        
        # Extract build wrappers (credentials binding, etc.)
        $buildWrappersList = @()
        if ($xmlConfig.project.buildWrappers) {
            $xmlConfig.project.buildWrappers.ChildNodes | ForEach-Object {
                $wrapperType = $_.LocalName -replace 'org\.jenkinsci\.plugins\.', '' -replace 'hudson\.plugins\.', ''
                $buildWrappersList += $wrapperType
            }
        }
        
        # Create comprehensive hash for similarity detection (excluding job name)
        $configString = "$($gitUrls -join '|')|$($gitBranches -join '|')|$($buildStepsList -join '|')|$($allCommands -join '|')|$mavenGoals|$($triggersList -join '|')|$cronSchedule|$($paramsList -join '|')"
        $configBytes = [System.Text.Encoding]::UTF8.GetBytes($configString)
        $configHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($configBytes)) -Algorithm MD5).Hash
        
        # Build the job info object
        $jobInfo = [PSCustomObject]@{
            JobName = $job.name
            JobType = $jobType
            JobURL = $job.url
            Status = $job.color
            Disabled = if ($xmlConfig.project.disabled) { $xmlConfig.project.disabled } else { "false" }
            Description = (Get-XmlNodeText $xmlConfig.project.description) -replace "`n"," " -replace "`r"," " -replace "\s+"," "
            
            # Git Information
            Git_URLs = $gitUrls -join " | "
            Git_Branches = $gitBranches -join " | "
            Git_Credentials = $gitCredentials -join " | "
            
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
            
            # Commands/Scripts (first command only for summary)
            First_Command = if ($allCommands.Count -gt 0) { 
                $allCommands[0].Substring(0, [Math]::Min(300, $allCommands[0].Length)) 
            } else { "" }
            
            # Full commands for hash calculation
            Commands_Hash = if ($allCommands) { 
                $cmdBytes = [System.Text.Encoding]::UTF8.GetBytes(($allCommands -join ""))
                (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($cmdBytes)) -Algorithm MD5).Hash
            } else { "" }
            
            # Maven
            Maven_Goals = $mavenGoals
            
            # Post Build Actions
            Post_Build_Actions = $postBuildList -join " | "
            
            # Build Wrappers
            Build_Wrappers = $buildWrappersList -join " | "
            
            # Node/Label
            Assigned_Node = if ($xmlConfig.project.assignedNode) { Get-XmlNodeText $xmlConfig.project.assignedNode } else { "any" }
            Can_Roam = if ($xmlConfig.project.canRoam) { $xmlConfig.project.canRoam } else { "true" }
            
            # JDK
            JDK = if ($xmlConfig.project.jdk) { Get-XmlNodeText $xmlConfig.project.jdk } else { "default" }
            
            # Configuration Hash (for duplicate detection)
            Config_Hash = $configHash
        }
        
        $jobDetails += $jobInfo
        
    } catch {
        Write-Host "  ERROR: $_" -ForegroundColor Red
        # Add error entry with partial info
        $jobDetails += [PSCustomObject]@{
            JobName = $job.name
            JobType = "ERROR"
            JobURL = $job.url
            Status = if ($job.color) { $job.color } else { "UNKNOWN" }
            Description = "Failed to process: $($_.Exception.Message)"
            Config_Hash = "ERROR"
        }
    }
}

# Export to CSV
$outputFile = "jenkins_jobs_export_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
$jobDetails | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

Write-Host "`n=== Export Completed! ===" -ForegroundColor Green
Write-Host "Output file: $outputFile" -ForegroundColor Yellow
Write-Host "Total jobs processed: $($jobDetails.Count)" -ForegroundColor Yellow
Write-Host "Successful: $(($jobDetails | Where-Object {$_.JobType -ne 'ERROR'}).Count)" -ForegroundColor Green
Write-Host "Errors: $(($jobDetails | Where-Object {$_.JobType -eq 'ERROR'}).Count)" -ForegroundColor Red

# Show summary statistics
Write-Host "`n=== Duplicate Analysis ===" -ForegroundColor Cyan
$validJobs = $jobDetails | Where-Object { $_.Config_Hash -ne "ERROR" }
$duplicateHashes = $validJobs | Group-Object Config_Hash | Where-Object { $_.Count -gt 1 } | Sort-Object Count -Descending

Write-Host "Potential duplicate groups found: $($duplicateHashes.Count)" -ForegroundColor Yellow

if ($duplicateHashes.Count -gt 0) {
    Write-Host "`nTop 10 Duplicate Groups:" -ForegroundColor Yellow
    $duplicateHashes | Select-Object -First 10 | ForEach-Object {
        Write-Host "`n  Group of $($_.Count) identical jobs:" -ForegroundColor White
        $_.Group | ForEach-Object { Write-Host "    - $($_.JobName)" -ForegroundColor Gray }
    }
}

# Git repository summary
Write-Host "`n=== Git Repository Summary ===" -ForegroundColor Cyan
$gitRepos = $validJobs | Where-Object { $_.Git_URLs -ne "" } | Group-Object Git_URLs | Sort-Object Count -Descending
Write-Host "Unique Git repositories used: $($gitRepos.Count)"
$gitRepos | Select-Object -First 5 | ForEach-Object {
    Write-Host "  - $($_.Count) jobs using: $($_.Name)" -ForegroundColor Gray
}

Write-Host "`n==> Upload '$outputFile' to Claude for detailed duplicate analysis! <==" -ForegroundColor Green
