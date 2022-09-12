#!/usr/bin/env pwsh
<#
.SYNOPSIS
Demonstrate HC3 Rest API importing VM using https (or SMB) - cloning with cloud-init customization - and VM configuration 
Easily set guest OS default user password, install packages required for docker and specify a docker run command (or other)
.PARAMETER clusterip
IP or DNS of Cluster/System to test the API against
.PARAMETER user
User name used to authenticate with the HC3 (or OIDC provier if selected)
.PARAMETER pass 
Password for HC3 cluster login 
.PARAMETER useOIDC 
bool true/false - specify whether to use OIDC login vs. local account
.PARAMETER VMtargetName
Name of resulting VM to create in HC3 via Clone - also set as hostname via cloud-init 
.PARAMETER VMmasterName 
Name of template / cloud-image to import, or search for if existing, and to clone from
.PARAMETER pathURI
Valid URI specification for VM import - typically would be SMB or trusted https
.PARAMETER VMmem
RAM bytes size for provisioned VM 
.PARAMETER VMnumVCPU 
Number of VCPU cores for provisioned VM 
.PARAMETER VMndiskGB
Size in GB to enlarge boot disk (first disk in cloned image) 
.PARAMETER tags
tag list to set on cloned VM
.PARAMETER guestPW
password to set in guest OS for default OS user
.PARAMETER sshimport
cloud-init instruction to import user SSH from public sources such as github - example - gh:ddemlow.  will read from $env:sshimport by default
.PARAMETER runcmd
valid runcmd string for target platform ... for example "docker run -P -d nginxdemos/hello"
.EXAMPLE
PSCore-CloudInitDemoLinux.ps1 -clusterip "192.168.1.240" -user admin -pass admin -useOIDC $false -VMtargetName target -VMmasterName "ubuntu18_04-cloud-init" -pathURI "smb://domain;administrator:password@192.168.1.248/share/" -VMmem 8589934592 -VMnumVCPU 2 -VMdiskGB 30
#>

[CmdletBinding()]
param(
#HC3 Cluster parameters
[string] $clusterip = "192.168.1.240" , #"127.0.0.1:3282" , #HC3 cluster info and login
  [string] $user = "admin",
  [string] $pass = "admin",
  [bool] $useOIDC = $false ,
 
#HC3 Template Import / Search parameters 
  [string] $VMmasterName = "ubuntu18_04-cloud-init" , #master cloud-init image to import and/or use
  [string]$pathURI="https://github.com/ddemlow/RestAPIExamples/raw/master/", #pathURI will have $VMmasterName apppended to it - send with /
  #Note: for https import - certificates must be valid / trusted by HC3 cluster - see below for SMB import syntax
  #[string]$pathURI="smb://remotedc;administrator:Scale2010@10.100.15.180/azure-sync/", #not used   



#HC3 VM Create parameters
  [string] $VMtargetName = "ieam3" ,
  [long] $VMmem = 8589934592 , #vram in bytes to provision to clones
  [int] $VMnumVCPU = 12 , #vcores to provision to clones
  [int] $VMdiskGB = 150 , #size to expand disk to in GB 
  [string] $tags = "DockerRuntimes" , #VM tag list to assign"
#Cloud-Init in Guest configuration variables - more hardcoded below could be moved to variables
  [string] $guestPW = "password" , # password to set on default guest OS user
  [string] $sshimport = $env:sshimport  #is allowed to be null - import user ssh keys
  #[string] $runcmd = 'docker run -d --device /dev/kvm:/dev/kvm --privileged --device /dev/net/tun:/dev/net/tun --name flatcar_vm mazzy/containervmm --flatcar-version=2605.6.0'
  #[string] $runcmd = "docker run -d progrium/stress --cpu 1 --io 1 --vm 1 --hdd 1 --vm-bytes 64K --hdd-bytes 4k --timeout 3600 "  #will be added to description 
  #[string] $runcmd = ' docker login -u ddemlow -p "b3cc244a-aad6-4739-9633-f7787581262d" && docker run -d --privileged -e "SPLUNK_START_ARGS=--accept-license" -e "SPLUNK_USER=root" -p "8000:8000" store/splunk/enterprise'  #will be added to description 
  )

$VM = @() #clear VM list at start 
$TaskTag = @()
$VMUUID = @()
$ErrorActionPreference = 'Stop'  #for safest operation - stop on any error

#Functions
 function Update-HC3VMList #updates contents of $VM variable with VM (VirDomain) info
  {
  #get list of VMs - virdomain information - update vm variable in script wide scope
  $Global:VM = Invoke-RestMethod -SkipCertificateCheck  -Method Get -Uri https://$Global:clusterip/rest/v1/VirDomain -WebSession $Script:mywebsession
  Write-Debug -Message "inside update VM function" 
}

  function Get-HC3VMUUID # given vm name - find UUID of matching VM 
  {
    Param(
      [string] $VMName 
  )  
  Update-HC3VMList  #refresh VM list from cluster
  Write-Host Looking for $VMName by name #handle case that VM was already on cluster / and confirm import
  $Script:VMobject = $VM | Select-Object | where-object -Property name -EQ $VMName
  $Script:VMUUID = $VMobject.UUID
  Write-Host found imported UUID - $VMUUID
  }

  function Wait-ScaleTask {
    Param(
        [string] $TaskTag 
    )

    Write-Host $Script:clusterip $TaskTag
    $retryDelay = [TimeSpan]::FromSeconds(1)
    $timeout = [TimeSpan]::FromSeconds(300)

    $timer = [Diagnostics.Stopwatch]::new()
    $timer.Start()

    while ($timer.Elapsed -lt $timeout)
    {
        Start-Sleep -Seconds $retryDelay.TotalSeconds
        $ErrorActionPreference = 'Continue'  #for safest operation - stop on any error
        $taskStatus = Invoke-RestMethod -SkipCertificateCheck -Uri https://$clusterip/rest/v1/TaskTag/$TaskTag -Method GET -WebSession $mywebsession
        Write-Debug  -Message "Wait function loop"
        if ($taskStatus.state -eq 'ERROR') {
            throw "Task '$TaskTag' failed!"
        }
        elseif ($taskStatus.state -eq 'COMPLETE') {
            Write-Verbose "Task '$TaskTag' completed!"
            $ErrorActionPreference = 'Stop'  #for safest operation - stop on any error
            return
        }
    }
    throw [TimeoutException] "Task '$TaskTag' failed to complete in $($timeout.Seconds) seconds"
    }
 
#create object for HC3 login oidc capable
$login = @{
        username = $user;
        password = $pass;
        useOIDC =  $useOIDC
    } | ConvertTo-Json
#login and HC3 session ID - is stored as powershell websession to allow re-use $mywebsession
$sessionid = Invoke-RestMethod -SkipCertificateCheck  -Method POST -Uri https://$clusterip/rest/v1/login -Body $login -ContentType 'application/json' -SessionVariable mywebSession


#Find UUID of $VMmasterName if VM already exists
Get-HC3VMUUID $VMmasterName

If ($VMUUID -eq $null) 
  {
  #IMPORT VM - for cloud-init template
  $ErrorActionPreference = 'Continue'  #for safest operation - stop on any error
    #create object for import options
    $importoptions = [ordered]@{
        source = [ordered]@{pathURI=$pathURI ; definitionFileName=$definitionFileName } ;
        template = [ordered]@{name=$name; tags=$tags}
            }
          
  #set import options
  $importoptions.source.pathURI=$pathURI +$VMmasterName
  $importoptions.source.definitionFileName=$VMmasterName  +".xml"
  $importoptions.template.name=$VMmasterName

  #convert to json
  $importoptionsJSON = $importoptions | ConvertTo-Json

  #hc3 vm import restapi - post to /VirDomain/import with json body to import template
  $ErrorActionPreference = 'Continue'  #for safest operation - stop on any error
  $NewVMTask = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/import -Body $importoptionsJSON  -ContentType 'application/json'  -WebSession $mywebsession
  Write-Host Importing VM $VMmasterName " Task" $NewVMTask.taskTag
  $ErrorActionPreference = 'Stop'  #for safest operation - stop on any error

  #TODO if task is not sucessful need to skip this or otherwise handle error - else function will loop forever, prob should fix in function regardless
  Wait-ScaleTask -TaskTag $NewVMTask.taskTag #wait for task to complete

#  lookup import UUID again - 2 options
#  Get-HC3VMUUID -VMName $VMmasterName
  $VMUUID = $NewVMTask.createdUUID
}

#add patch to change template to 0 vcpu to preserve template - this will cause accidental power on for template to fail to start
    $json = @{
        numVCPU = 0     
        } | ConvertTo-Json    
$NewVMTask = Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri https://$clusterip/rest/v1/VirDomain/$VMUUID -WebSession $mywebsession -Body $json -ContentType 'application/json'
  
#clone customized VM 
#yaml for meta-data cloud-init payload - here just sets unique host name
$metaData = @"
dsmode: local
# network-interfaces: |
#   auto ens3
#   iface ens3 inet loopback

#   iface ens3 inet static
#     address 192.168.1.200
#     netmask 255.255.255.0
#     gateway 192.168.1.1
local-hostname: 
"@ + $VMtargetName+
@" 
"@

#base64 encode meta-data
$metaData64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($metaData))
Write-Host cloud-init data
#TODO - should catch errors - likely indicating ivalid  yaml here 
$metaData | ConvertFrom-Yaml
Write-Host

# create user-data yaml structure
$userData = @'
#cloud-config
#apt_update: true
#apt_upgrade: true
password: '
'@ +  $guestPW +
@'
'
chpasswd: { expire: False }
ssh_pwauth: True
ssh_import_id: '
'@ + $sshimport +
@'
'
#ssh_authorized_keys:
#  - ssh-rsa 
apt: {sources: {docker.list: {source: 'deb [arch=amd64] https://download.docker.com/linux/ubuntu $RELEASE stable', keyid: 9DC858229FC7DD38854AE2D88D81803C0EBFCD88}}}
packages: [qemu-guest-agent, docker-ce, docker-ce-cli, docker-compose, unzip, ansible]
#mounts:
#  - [ /dev/disk/by-label/cidata, /media ]
bootcmd:
  - [ sh, -c, 'sudo echo GRUB_CMDLINE_LINUX="nomodeset" >> /etc/default/grub' ]
  - [ sh, -c, 'sudo echo GRUB_GFXPAYLOAD_LINUX="1024x768" >> /etc/default/grub' ]
  - [ sh, -c, 'sudo echo GRUB_DISABLE_LINUX_UUID=true >> /etc/default/grub' ]
  - [ sh, -c, 'sudo update-grub' ]
runcmd: 
  - '
'@ +  $runcmd +
@'
'
write_files:
- content: 
'@ +  $clusterip +
@'

  path: /clusterip.txt 

- path: /etc/environment
  content: |
    HC3_IP="
'@ + $clusterip +
@'
"

'@

#TODO - should catch errors - likely indicating ivalid  yaml here 
Write-Host user-data 
$userData | ConvertFrom-Yaml   #
Write-Host

#base64 encode user-data
$userData64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($userData))

#combine cloudInit data json
$cloudInitData = @{
        userData = $userData64
        metaData = $metaData64
} 

#create virdomain clone body
$json = @{
    snapUUID = ""
    template = @{
        name =  $VMtargetName
        description = $runcmd + " PASSWORD: " + $guestPW + " SERIAL "   
        tags = $tags 
        cloudInitData = $cloudInitData
        mem = $VMmem
        numVCPU = $VMnumVCPU       
    } 
} | ConvertTo-Json

#submit the clone operation
    $NewVMTask = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/$VMUUID/clone -WebSession $mywebsession -Body $json -ContentType 'application/json'
    $tasktag = $NewVMTask.taskTag
    $CreatedUUID=$NewVMTask.createdUUID
    #Wait for clone to complete to start it
    Write-Host Cloning $VMtargetName

    Wait-ScaleTask -TaskTag $tasktag 

#get VM info detail for new vm
$CreatedVM=Invoke-RestMethod -SkipCertificateCheck -Method Get -Uri https://$clusterip/rest/v1/VirDomain/$CreatedUUID -WebSession $mywebsession 

#expand the virtual disk to variable size above ... and change the mac address?

#getblockdev - use simple approach assuming first disk [0]
$CreatedBlockDev=$CreatedVM.blockDevs[0].uuid

$jsonDISK = @'
{
    "capacity": 
'@ + $VMdiskGB*1000*1000*1000 +
@' 

}
'@

#enlarge first vsd 
$PatchVMDisk=Invoke-RestMethod -SkipCertificateCheck -Method Patch -Uri https://$clusterip/rest/v1/VirDomainBlockDevice/$CreatedBlockDev -WebSession $mywebsession -Body $jsonDISK -ContentType 'application/json'
Write-Host Enlarging first disk to $VMdiskGB

# START VM
    $jsonstart = ConvertTo-Json @(@{
        actionType = 'START'
        virDomainUUID = $CreatedUUID
        })

    $task = Invoke-RestMethod -SkipCertificateCheck  -Method Post -Uri https://$clusterip/rest/v1/VirDomain/action -WebSession $mywebsession -Body $jsonSTART -ContentType 'application/json'

    Write-Host "Starting " $VMtargetName
    #Wait for vm to start 
    Wait-ScaleTask -TaskTag $task.taskTag


#TODO - wait for IP or use dns name and create local docker context - and run docker command
#docker context create --docker host=ssh://ubuntu@ubuntu-pi.local --description "ubuntu-pi.local" ubuntu-pi
#docker context use ubuntu-pi
#docker container stats
#docker ps --no-trunc --format "{{json .}}" | ConvertFrom-Json | Format-List
#docker ps --no-trunc --format "{{json .}}" | ConvertFrom-Json | Format-Table Names, Image, State
#could also connect remotely to docker rest api vs. using local docker cli like above




Write-Host log out $user from HC3 $clusterip 
Invoke-RestMethod -SkipCertificateCheck  -Method POST -Uri https://$clusterip/rest/v1/logout -WebSession $mywebsession