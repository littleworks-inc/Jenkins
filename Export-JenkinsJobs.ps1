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
    if ($null -eq $node) { return "" }
    if ($node -is [string]) { return $node }
    if ($node.'#text') { return $node.'#text' }
    return $node.ToString()
}

# Function to fix XML 1.1 and parse safely
function Get-ParsedXml {
    param([string]$xmlContent)
    
    try {
        # Replace XML 1.1 with 1.0
        $fixedXml = $xmlContent -replace "<?xml version='1\.1'", "<?xml version='1.0'"
        $fixedXml = $fixedXml -replace '<?xml version="1\.1"', '<?xml version="1.0"'
        
        # Parse XML
        $xml = New-Object System.Xml.XmlDocument
        $xml.LoadXml($fixedXml)
        return $xml
    }
    catch {
        Write-Host "    XML Parse Error: $_" -ForegroundColor Red
        return $null
    }
}

# Get all jobs
Write-Host "Fetching all Jenkins jobs..." -ForegroundColor Green
$jobsUrl = "$jenkinsUrl/api/json?tree=jobs[name,url,color]"

try {
    $response = Invoke-RestMethod -Uri $jobsUrl -Headers $headers -Method Get
    $allJobs = $response.jobs
    Write-Host "Found $($allJobs.Count) jobs" -ForegroundColor Yellow
}
catch {
    Write-Host "Failed to fetch jobs list: $_" -ForegroundColor Red
    exit 1
}

# Prepare result array
$jobDetails = @()
$counter = 0
$successCount = 0
$errorCount = 0

foreach ($job in $allJobs) {
    $counter++
    Write-Host "[$counter/$($allJobs.Count)] Processing: $($job.name)" -ForegroundColor Cyan
    
    try {
        # Get job config XML as raw text
        $configUrl = "$jenkinsUrl/job/$([uri]::EscapeDataString($job.name))/config.xml"
        $configResponse = Invoke-WebRequest -Uri $configUrl -Headers $headers -Method Get
        $configRaw = $configResponse.Content
        
        # Parse XML with fix
        $xmlConfig = Get-ParsedXml -xmlContent $configRaw
        
        if ($null -eq $xmlConfig) {
            throw "Failed to parse XML"
        }
        
        # Determine job type
        $jobType = $xmlConfig.DocumentElement.LocalName
        
        # Extract Git URLs
        $gitUrls = @()
        $gitBranches = @()
        $gitCredentials = @()
        
        $scmNodes = $xmlConfig.SelectNodes("//scm[@class='hudson.plugins.git.GitSCM']//userRemoteConfigs//hudson.plugins.git.UserRemoteConfig")
        foreach ($node in $scmNodes) {
            $url = $node.SelectSingleNode("url")
            if ($url) { $gitUrls += $url.InnerText }
            
            $cred = $node.SelectSingleNode("credentialsId")
            if ($cred) { $gitCredentials += $cred.InnerText }
        }
        
        $branchNodes = $xmlConfig.SelectNodes("//scm[@class='hudson.plugins.git.GitSCM']//branches//hudson.plugins.git.BranchSpec/name")
        foreach ($node in $branchNodes) {
            $gitBranches += $node.InnerText
        }
        
        # Extract parameters
        $paramsList = @()
        $paramNodes = $xmlConfig.SelectNodes("//properties//hudson.model.ParametersDefinitionProperty//parameterDefinitions//*[contains(name(),'ParameterDefinition')]")
        foreach ($node in $paramNodes) {
            $paramName = $node.SelectSingleNode("name")
            $paramDefault = $node.SelectSingleNode("defaultValue")
            $paramType = $node.LocalName -replace '.*\.', '' -replace 'ParameterDefinition', ''
            
            if ($paramName) {
                $defVal = if ($paramDefault) { $paramDefault.InnerText } else { "N/A" }
                $paramsList += "${paramType}:$($paramName.InnerText)=${defVal}"
            }
        }
        
        # Extract build steps
        $buildStepsList = @()
        $builderNodes = $xmlConfig.SelectNodes("//builders/*")
        foreach ($node in $builderNodes) {
            $stepType = $node.LocalName -replace '.*\.', ''
            $buildStepsList += $stepType
        }
        
        # Extract commands
        $allCommands = @()
        
        # Shell commands
        $shellNodes = $xmlConfig.SelectNodes("//builders//hudson.tasks.Shell/command")
        foreach ($node in $shellNodes) {
            $allCommands += "SHELL: " + $node.InnerText.Trim()
        }
        
        # Batch commands
        $batchNodes = $xmlConfig.SelectNodes("//builders//hudson.tasks.BatchFile/command")
        foreach ($node in $batchNodes) {
            $allCommands += "BATCH: " + $node.InnerText.Trim()
        }
        
        # PowerShell commands
        $psNodes = $xmlConfig.SelectNodes("//builders//hudson.plugins.powershell.PowerShell/command")
        foreach ($node in $psNodes) {
            $allCommands += "POWERSHELL: " + $node.InnerText.Trim()
        }
        
        # Maven goals
        $mavenNode = $xmlConfig.SelectSingleNode("//builders//hudson.tasks.Maven/targets")
        $mavenGoals = if ($mavenNode) { $mavenNode.InnerText } else { "" }
        
        # Extract triggers
        $triggersList = @()
        $cronSchedule = ""
        $triggerNodes = $xmlConfig.SelectNodes("//triggers/*")
        foreach ($node in $triggerNodes) {
            $triggerType = $node.LocalName -replace '.*\.', ''
            $triggersList += $triggerType
            
            $specNode = $node.SelectSingleNode("spec")
            if ($specNode) { $cronSchedule = $specNode.InnerText }
        }
        
        # Extract post-build actions
        $postBuildList = @()
        $publisherNodes = $xmlConfig.SelectNodes("//publishers/*")
        foreach ($node in $publisherNodes) {
            $actionType = $node.LocalName -replace '.*\.', ''
            $postBuildList += $actionType
        }
        
        # Extract build wrappers
        $buildWrappersList = @()
        $wrapperNodes = $xmlConfig.SelectNodes("//buildWrappers/*")
        foreach ($node in $wrapperNodes) {
            $wrapperType = $node.LocalName -replace '.*\.', ''
            $buildWrappersList += $wrapperType
        }
        
        # Get description
        $descNode = $xmlConfig.SelectSingleNode("//description")
        $description = if ($descNode) { 
            $descNode.InnerText -replace "`n"," " -replace "`r"," " -replace "\s+"," " 
        } else { "" }
        
        # Get disabled status
        $disabledNode = $xmlConfig.SelectSingleNode("//disabled")
        $disabled = if ($disabledNode) { $disabledNode.InnerText } else { "false" }
        
        # Get node assignment
        $nodeNode = $xmlConfig.SelectSingleNode("//assignedNode")
        $assignedNode = if ($nodeNode) { $nodeNode.InnerText } else { "any" }
        
        $canRoamNode = $xmlConfig.SelectSingleNode("//canRoam")
        $canRoam = if ($canRoamNode) { $canRoamNode.InnerText } else { "true" }
        
        # Create hash for duplicate detection
        $configString = "$($gitUrls -join '|')|$($gitBranches -join '|')|$($buildStepsList -join '|')|$($allCommands -join '|')|$mavenGoals|$($triggersList -join '|')|$cronSchedule|$($paramsList -join '|')"
        $configBytes = [System.Text.Encoding]::UTF8.GetBytes($configString)
        $configHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($configBytes)) -Algorithm MD5).Hash
        
        # Commands hash
        $commandsHash = ""
        if ($allCommands) {
            $cmdBytes = [System.Text.Encoding]::UTF8.GetBytes(($allCommands -join ""))
            $commandsHash = (Get-FileHash -InputStream ([System.IO.MemoryStream]::new($cmdBytes)) -Algorithm MD5).Hash
        }
        
        # Build the job info object
        $jobInfo = [PSCustomObject]@{
            JobName = $job.name
            JobType = $jobType
            JobURL = $job.url
            Status = $job.color
            Disabled = $disabled
            Description = $description
            Git_URLs = $gitUrls -join " | "
            Git_Branches = $gitBranches -join " | "
            Git_Credentials = $gitCredentials -join " | "
            SCM_Type = if ($xmlConfig.SelectSingleNode("//scm/@class")) { 
                $xmlConfig.SelectSingleNode("//scm/@class").Value 
            } else { "None" }
            Triggers = $triggersList -join " | "
            Cron_Schedule = $cronSchedule
            Parameters = $paramsList -join " | "
            Parameter_Count = $paramsList.Count
            Build_Steps = $buildStepsList -join " | "
            Build_Steps_Count = $buildStepsList.Count
            First_Command = if ($allCommands.Count -gt 0) { 
                $allCommands[0].Substring(0, [Math]::Min(300, $allCommands[0].Length)) 
            } else { "" }
            Commands_Hash = $commandsHash
            Maven_Goals = $mavenGoals
            Post_Build_Actions = $postBuildList -join " | "
            Build_Wrappers = $buildWrappersList -join " | "
            Assigned_Node = $assignedNode
            Can_Roam = $canRoam
            Config_Hash = $configHash
        }
        
        $jobDetails += $jobInfo
        $successCount++
        
    } catch {
        Write-Host "  ERROR: $($_.Exception.Message)" -ForegroundColor Red
        $errorCount++
        
        # Add minimal error entry
        $jobDetails += [PSCustomObject]@{
            JobName = $job.name
            JobType = "ERROR"
            JobURL = $job.url
            Status = if ($job.color) { $job.color } else { "UNKNOWN" }
            Description = "Failed: $($_.Exception.Message)"
            Config_Hash = "ERROR"
        }
    }
}

# Export to CSV
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$outputFile = "jenkins_jobs_export_$timestamp.csv"
$jobDetails | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "EXPORT COMPLETED!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Output file: $outputFile" -ForegroundColor Yellow
Write-Host "Total jobs: $($allJobs.Count)" -ForegroundColor White
Write-Host "Successful: $successCount" -ForegroundColor Green
Write-Host "Errors: $errorCount" -ForegroundColor Red

# Duplicate Analysis
Write-Host "`n=== DUPLICATE ANALYSIS ===" -ForegroundColor Cyan
$validJobs = $jobDetails | Where-Object { $_.Config_Hash -ne "ERROR" -and $_.Config_Hash -ne "" }
$duplicateGroups = $validJobs | Group-Object Config_Hash | Where-Object { $_.Count -gt 1 } | Sort-Object Count -Descending

if ($duplicateGroups.Count -gt 0) {
    Write-Host "Found $($duplicateGroups.Count) groups of potential duplicates" -ForegroundColor Yellow
    Write-Host "`nTop 10 Duplicate Groups:" -ForegroundColor Yellow
    
    $duplicateGroups | Select-Object -First 10 | ForEach-Object {
        Write-Host "`n  [$($_.Count) identical jobs]" -ForegroundColor Magenta
        $_.Group | ForEach-Object { 
            Write-Host "    - $($_.JobName)" -ForegroundColor Gray 
        }
    }
} else {
    Write-Host "No exact duplicates found" -ForegroundColor Green
}

# Git Repository Summary
Write-Host "`n=== GIT REPOSITORIES ===" -ForegroundColor Cyan
$gitJobs = $validJobs | Where-Object { $_.Git_URLs -ne "" }
$gitRepos = $gitJobs | Group-Object Git_URLs | Sort-Object Count -Descending

Write-Host "Jobs using Git: $($gitJobs.Count)" -ForegroundColor White
Write-Host "Unique repositories: $($gitRepos.Count)" -ForegroundColor White

if ($gitRepos.Count -gt 0) {
    Write-Host "`nTop 5 repositories:" -ForegroundColor Yellow
    $gitRepos | Select-Object -First 5 | ForEach-Object {
        Write-Host "  [$($_.Count) jobs] $($_.Name)" -ForegroundColor Gray
    }
}

Write-Host "`n========================================" -ForegroundColor Green
Write-Host "Next step: Upload '$outputFile' to Claude for AI analysis!" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Green
