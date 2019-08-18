#!/usr/bin/env pwsh
#Requires -Version 6

param (
    # project root path
    [string]$root_folder = $PWD,
    #the versions of vscode to support; Defaults to 'master'
    [string[]]$VSCodeVersions = @('master'),
    #the base Electron versions to get natives for 
    [string[]]$ElectronVersions = @() ,
    #the base Node version(s) to get natives form 
    [string[]]$NodeVersions = @() ,
    # the platforms 
    [string[]]$platforms = @("win32","darwin","linux") ,
    #the processor architectures 
    [string[]]$architectures = @("x64","ia32"),
    # clean native_modules folder 
    [switch] $Clean,
    # do not copy,
    [switch] $NoCopy,
    #do not detect the version of node running on this workstation
    [switch] $IgnoreNodeVersion
) 
#Check if script is started in project root folder
if (-not( (Test-Path './package.json') -and (Test-Path './node_modules'))){
    Write-Error 'Please start in root of project. (package.json and node_modules were not found)'
    return -1
}

$package = Get-Content '.\package.json' | ConvertFrom-Json
# check if the npm dependencies are install
# NodeJS dependencies 
#    npm install @serialport --save
#    npm install node-abi --save || --save-dev
#    npm install node-abi@1.5.0 --save
# dev only (unless runtime download needed )
#    npm install prebuild-install --save-dev
# (c) jos_verlinde@hotmail.com
# licence MIT

foreach ($mod in "node-abi","prebuild-install","serialport" ){
    if(-not ( $package.devDependencies."$mod" -or $package.dependencies."$mod") ) {
        Write-Error "Missing npm dependency: $mod. Please run 'npm install $mod --save-dev'" 
        return   
    }
}

# get both sets of versions into a single list {runtime}-{version}
$VersionList = @()
foreach ($v in $ElectronVersions) {
    $VersionList=$VersionList + "electron-$v"
}
foreach ($v in $NodeVersions) {
    $VersionList=$VersionList + "node-$v"
}

# the (sub module = @serialport/bindings)
$module_name = '@serialport/bindings'
# this is where our (sub) module lives
$module_folder = Join-Path $root_folder -ChildPath "node_modules/$module_name"
#this is the repo storage location for the native modules
$native_modules = Join-Path $root_folder -ChildPath 'native_modules'
$native_folder = Join-Path $native_modules -ChildPath $module_name

function ReadVsCodeElectronVersion {
    param ( [string]$GitTag = 'master' )
# Read the electron version from the .yarnrc file in the VSCode Repo
# For unauthenticated requests, the rate limit allows for up to 60 requests per hour, which is OK
    try {
        $git_url = "https://raw.githubusercontent.com/microsoft/vscode/$GitTag/.yarnrc"
        $yaml = Invoke-WebRequest $git_url -UserAgent 'josverl mp-download'| Select-Object -Expand Content 
        $yaml = $yaml.Split("`n")
        $version = $yaml | Select-String -Pattern '^target +"(?<targetversion>[0-9.]*)"' -AllMatches | 
                Foreach-Object {$_.Matches} | 
                Foreach-Object {$_.Groups} |
                Where-Object Name -ieq 'targetversion' |
                Select-Object -ExpandProperty Value
        return $version
    } catch {
        Write-warning "Unable to find the Electron version used by VSCode [$GitTag]. Does it exist ?"
        return $null
    }
}

function RecentVSCodeVersions ($Last = 3) {
    try {
        $output = &git ls-remote --tags https://github.com/microsoft/vscode.git 
        $VersionTags = foreach( $line in $output) {
            $tag = $line.Split('refs/tags/')[1]
            try{ 
                $_ = [version]$tag
                Write-Output $tag
            } catch { 
                #not a tag
            }
        } 
        $Recent = $VersionTags | Sort-Object {[version]$_ } | 
                    Group-Object {([version]$_).Major + " " + ([version]$_).Minor } |
                    Select-Object -Property Group -Last $Last |
                    ForEach-Object{ write-output $_.Group[0]}  
        return $Recent
    } catch {
        return $null
    }
}

function runNodeCommand ([string]$cmd) {
    # run a simple command in Node and get the printed outout
    try { 
        if ($IsWindows) {
            $result = &node.exe --print $cmd 
        } else {
            $result = &node --print $cmd
        }
        return $result
    } catch {
        Write-Error "Unable to run NodeJS command"
        return $null
    }
}

function getABI([string]$runtime = "", [string]$version = "") {
    # get the abi version 
    # requires: npm install node-abi [...]
    $cmd = "var getAbi = require('node-abi').getAbi;getAbi('$version','$runtime')"
    $ABI_ver = runNodeCommand $cmd
    return $ABI_ver
}

function DownloadPrebuild {

    param( 
        # Runtime (node/electron)     
        [string] $runtime = 'electron', 
        # Electron version     
        [string] $version, 
        # Platform win32/darwin/linux
        [string] $platform, 
        # CPU architecture x64 /ia32 
        [string] $arch,
        [string] $prefix = "$module_name@"
        # $module_folder  #todo: add param for more flexibility  
    )
    if ($platform -ieq 'darwin' -and $arch -ieq 'ia32'){
        # mac = only 64 bit 
        return $false
    }

    # move into bindings folder to download
    # todo: add error chcking to set-location 
    Set-Location $module_folder
    try {
        if ($IsWindows) {
            # &".\node_modules\.bin\prebuild-install.cmd" --runtime $runtime --target $version --arch $arch --platform $platform --tag-prefix $prefix
            &"$root_folder\node_modules\.bin\prebuild-install.cmd" --runtime $runtime --target $version --arch $arch --platform $platform --tag-prefix $prefix
        } else {
            # linux / mac : same command , slightly different path
            node_modules/.bin/prebuild-install --runtime $runtime --target $version --arch $arch --platform $platform --tag-prefix $prefix
            &"$root_folder/node_modules/.bin/prebuild-install" --runtime $runtime --target $version --arch $arch --platform $platform --tag-prefix $prefix
        }
    }  catch {
        Write-Error "Unable to run prebuild-install. Did you run 'npm add prebuild-install --save-dev ?'" 
    }
    Set-Location $root_folder
    #true for success 
    return $LASTEXITCODE -eq 0
}


# -Clean : empty the previous prebuilds 
if ($Clean ){
    
    Write-Host -f Yellow 'Cleanup the native_modules folder'
    remove-item $native_modules -Recurse -ErrorAction SilentlyContinue 
}

# ensure native_modules directory exists
$_ = new-item $native_modules -ItemType Directory -ErrorAction SilentlyContinue 

# Store doc in native modules folder 
$docs_file = Join-Path $native_modules -ChildPath "included_runtimes.md"
# generate / append Document for electron-abi versions
if (Test-Path $docs_file){
    "Includes support for electron/node versions:" | Out-File -filepath $docs_file -Append
} else {
    "Includes support for electron/node versions:" | Out-File -filepath $docs_file 
}

# Read target vscode version 

try {
    $version = $package.engines.vscode.Replace('^','')
    if ($version -notin $VSCodeVersions) {
        Write-Host -F Blue "Add VSCode [$version] version from package.json"
        $VSCodeVersions = $VSCodeVersions + $version
        
    }
} catch {
    Write-Warning 'No vscode engine version found'
}

#Add support for all newer vscode versions based on date ?
foreach($version in (RecentVSCodeVersions -Last 3) ){
    if ($version -notin $VSCodeVersions) {
        Write-Host -F Blue "Add recent VSCode [$version] version"
        $VSCodeVersions = $VSCodeVersions + $version
    }
}

# get/add electron versions for all relevant vscode versions 
foreach ($tag in $VSCodeVersions ){
    $version = ReadVsCodeElectronVersion -GitTag $tag
    if ($version) {
        # Add to documentation
        $ABI_ver = getABI 'electron' $version
        "* VSCode [$tag] uses Electron $version , ABI: $ABI_ver"| Out-File -filepath $docs_file -Append

        if ( "electron-$version" -in $VersionList ) {
            Write-Host -F Green "VSCode [$tag] uses a known version of Electron: $version , ABI: $ABI_ver"
        }else {
            Write-Host -F Blue "VSCode [$tag] uses an additional version of Electron: $version ABI: $ABI_ver, that will be used/added to the prebuild versions to download"
            $VersionList=$VersionList + "electron-$version" 
        } 
    }
}
# sort the list 
if ($VersionList.Count){
    $VersionList= $VersionList | Sort-Object
}
# -DetectNodeVersion : add this workstations node version if  specified 
if ( -not $IgnoreNodeVersion) {
    $version = runNodeCommand 'process.versions.node'
    if ( "node-$version" -notin $VersionList ) {
        $VersionList=$VersionList + "node-$version" | Sort-Object
        Write-Host -F Blue "Detected and added NodeJS version $version"
    }
}

# show initial listing 
foreach ($item in $VersionList) {
    #split runtime-version 
    $runtime, $version = $item.split('-')
    # handle platforms
    $ABI_ver = getABI $runtime $version
    Write-Host -F Blue "$runtime $version uses ABI $ABI_ver"
}

#now the processing 
foreach ($item in $VersionList) {
    #split runtime-version 
    $runtime, $runtime_ver = $item.split('-')

    # Get the ABI version for node/electron version x.y.z 
    $ABI_ver = getABI $runtime $runtime_ver

    # add to documentation
    "* $runtime $runtime_ver uses ABI $ABI_ver" | Out-File -FilePath $docs_file -Append 
    foreach ($platform in $platforms){
        foreach ($arch in $architectures){
            Write-Host -f green "Download prebuild native binding for runtime $runtime : $runtime_ver, abi: $abi_ver, $platform, $arch"
            $OK = DownloadPrebuild -version $runtime_ver -platform $platform -arch $arch -runtime $runtime
            if ( $OK ) {
                try {
                    #OK , now copy the platform folder 
                    # from : \@serialport\bindings\build\Release\bindings.node
                    # to a folder per "abi<ABI_ver>-<platform>-<arch>"
                    #$dest_folder = Join-Path $module_folder -ChildPath "abi$ABI_ver-$platform-$arch"
                    switch ($runtime) {
                        'node' {        # use the node version for the path ( implemended by binding) 
                                        # supported by ('binding')('serialport')
                                        # <root>/node_modules/@serialport/bindings/compiled/<version>/<platform>/<arch>/binding.node
                                        # Note: runtime is not used in path 
                                        $dest_file = Join-Path $native_folder -ChildPath "compiled/$runtime_ver/$platform/$arch/bindings.node"
                        }
                        'electron' {# node-pre-gyp - use the ABIversion for the path (uses less space, better compat)
                                        # ./lib/binding/{node_abi}-{platform}-{arch}`
                                        # \node_modules\@serialport\bindings\lib\binding\node-v64-win32-x64\bindings.node
                                        # Note: runtime is hardcoded as 'node' in path
                                        $dest_file = Join-Path $native_folder -ChildPath "lib/binding/node-v$abi_ver-$platform-$arch/bindings.node" 
                        }
                        'prebuildify' { # https://github.com/prebuild/node-gyp-build 
                                        # <root>/node_modules/@serialport/bindings/prebuilds/<platform>-<arch>\<runtime>abi<abi>.node
                                        #todo : file dest copy 
                                        $dest_file = Join-Path $native_folder -ChildPath "prebuilds/$platform-$arch/($runtime)abi$abi_ver.node"  }
                        default {
                            Write-Warning 'unknown path pattern'
                        }
                    }
                    # make sure the containing folder exists
                    new-item (split-Path $dest_file -Parent) -ItemType Directory -ErrorAction SilentlyContinue | Out-Null
                    # cope all *.node native bindings
                    $_ = Copy-Item ".\node_modules\$module_name\build\Release\*.node" $dest_file -Force 
                    Write-Host " -> $dest_file"
                    # add to documentation.md
                    $msg = "   - {0,-8}, {1,-4}, {2}" -f $platform, $arch , ($dest_file.Replace($root_folder,'.'))
                    Out-File -InputObject $msg -FilePath $docs_file -Append 
                } catch {
                    Write-Warning "Error while copying prebuild bindings for runtime $runtime : $runtime_ver, abi: $abi_ver, $platform, $arch"
                } 

            } else { # no need to show multiple warnings 
                # Write-Warning "no prebuild bindings for electron: $runtime_ver, abi: $abi_ver, $platform, $arch"
            }
        }
    }
} 

# Always Clean module release folder to prevent the wrong runtime from being blocking other platforms  
Remove-Item "$module_folder/build/release" -Recurse -Force
write-host -ForegroundColor Green  "`nCleaned the '$module_folder/build/release' folder, to prevent including and break cross-platform portability."

# -NoCopy : to avoid copying 
if (-not $NoCopy) {
    write-host -ForegroundColor Green "Copy all /native_modules into the /node_modules for cross platform packaging "
    Copy-Item -Path (join-path $native_modules '*')-Destination (Join-Path $root_folder 'node_modules')  -Force -Recurse -PassThru | 
        Where-Object {!$_.PSIsContainer} | ForEach-Object{$_.DirectoryName}
}

Write-Host -ForegroundColor blue "Platform bindings are listed in: $docs_file"

