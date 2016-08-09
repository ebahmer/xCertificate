#Requires -Version 4.0

#region localizeddata
if (Test-Path "${PSScriptRoot}\${PSUICulture}")
{
    Import-LocalizedData `
        -BindingVariable LocalizedData `
        -Filename MSFT_xCertReq.strings.psd1 `
        -BaseDirectory "${PSScriptRoot}\${PSUICulture}"
}
else
{
    #fallback to en-US
    Import-LocalizedData `
        -BindingVariable LocalizedData `
        -Filename MSFT_xCertReq.strings.psd1 `
        -BaseDirectory "${PSScriptRoot}\en-US"
}
#endregion

# Import the common certificate functions
Import-Module -Name ( Join-Path `
    -Path (Split-Path -Path $PSScriptRoot -Parent) `
    -ChildPath '\MSFT_xCertificateCommon\MSFT_xCertificateCommon.psm1' )

function Get-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Collections.Hashtable])]
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Subject,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CAServerFQDN,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CARootName,

        [System.Management.Automation.PSCredential]
        $Credential,

        [System.Boolean]
        $AutoRenew
    )

    # The certificate authority, accessible on the local area network
    [System.String] $CA = "'$CAServerFQDN\$CARootName'"

    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.GettingCertReqStatusMessage -f $Subject,$CA)
        ) -join '' )

    $Cert = Get-Childitem -Path Cert:\LocalMachine\My |
        Where-Object -FilterScript {
            $_.Subject -eq "CN=$Subject" -and `
            $_.Issuer.split(',')[0] -eq "CN=$CARootName"
        }

    # If multiple certs have the same subject and were issued by the CA, return the newest
    $Cert = $Cert | Sort-Object -Property NotBefore -Descending | Select-Object -First 1

    if ($Cert)
    {
        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.CertificateExistsMessage -f $Subject,$CA,$Cert.Thumbprint)
            ) -join '' )

        $returnValue = @{
            Subject      = $Cert.Subject.split(',')[0].replace('CN=','')
            CAServerFQDN = '' # This value can't be determined from the cert
            CARootName   = $Cert.Issuer.split(',')[0].replace('CN=','')
        }
    }
    else
    {
        $returnValue = @{}
    }

    $returnValue
} # end function Get-TargetResource

function Set-TargetResource
{
    [CmdletBinding()]
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Subject,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CAServerFQDN,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CARootName,

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $KeyLength = '1024',

        [parameter(Mandatory = $false)]
        [System.Boolean]
        $Exportable = $true,

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ProviderName = '"Microsoft RSA SChannel Cryptographic Provider"',

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $OID = '1.3.6.1.5.5.7.3.1',

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $KeyUsage = '0xa0',
        
        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CertificateTemplate = 'WebServer',
        
        [System.Management.Automation.PSCredential]
        $Credential,

        [System.Boolean]
        $AutoRenew
    )

    # The certificate authority, accessible on the local area network
    [System.String] $CA = "'$CAServerFQDN\$CARootName'"

    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.StartingCertReqMessage -f $Subject,$CA)
        ) -join '' )

    # If the Subject does not contain a full X500 path, construct just the CN
    if (($Subject.split('=').Count) -eq 1)
    {
        [System.String] $Subject = "CN=$Subject"
    }

    # If we should look for renewals, check for existing certs
    if ($AutoRenew)
    {
        $Cert = Get-Childitem -Path Cert:\LocalMachine\My |
            Where-Object -FilterScript {
                $_.Subject -eq $Subject -and `
                $_.Issuer.split(',')[0] -eq "CN=$CARootName" -and `
                $_.NotAfter -lt (Get-Date).AddDays(30)
            }

        # If multiple certs have the same subject and were issued by the CA and are 30 days from expiration, return the newest
        $Thumbprint = $Cert | Sort-Object -Property NotBefore -Descending |
            Select-Object -First 1 |
            ForEach-Object -Process { $_.Thumbprint }
    }

    # Information that will be used in the INF file to generate the certificate request
    # In future versions, select variables from the list below could be moved to parameters!
    [System.String] $Subject             = "`"$Subject`""
    [System.String] $KeySpec             = '1'
    [System.String] $MachineKeySet       = 'TRUE'
    [System.String] $SMIME               = 'FALSE'
    [System.String] $PrivateKeyArchive   = 'FALSE'
    [System.String] $UserProtected       = 'FALSE'
    [System.String] $UseExistingKeySet   = 'FALSE'
    [System.String] $ProviderType        = '12'
    [System.String] $RequestType         = 'CMC'

    # A unique identifier for temporary files that will be used when interacting with the command line utility
    [system.guid] $GUID = [system.guid]::NewGuid().guid
    [System.String] $WorkingPath = Join-Path -Path $ENV:Temp -ChildPath "xCertReq-$Guid"
    [System.String] $InfPath = [System.IO.Path]::ChangeExtension($WorkingPath,'.inf')
    [System.String] $ReqPath = [System.IO.Path]::ChangeExtension($WorkingPath,'.req')
    [System.String] $CerPath = [System.IO.Path]::ChangeExtension($WorkingPath,'.cer')
    [System.String] $RspPath = [System.IO.Path]::ChangeExtension($WorkingPath,'.rsp')

    # Create INF file
    $requestDetails = @"
[NewRequest]
Subject = $Subject
KeySpec = $KeySpec
KeyLength = $KeyLength
Exportable = $($Exportable.ToString().ToUpper())
MachineKeySet = $MachineKeySet
SMIME = $SMIME
PrivateKeyArchive = $PrivateKeyArchive
UserProtected = $UserProtected
UseExistingKeySet = $UseExistingKeySet
ProviderName = $ProviderName
ProviderType = $ProviderType
RequestType = $RequestType
KeyUsage = $KeyUsage
[RequestAttributes]
CertificateTemplate = $CertificateTemplate
[EnhancedKeyUsageExtension]
OID = $OID
"@
    if ($Thumbprint)
    {
        $requestDetails += @"
RenewalCert = $Thumbprint
"@
    }
    Set-Content -Path $InfPath -Value $requestDetails

    # Certreq.exe:
    # Syntax: https://technet.microsoft.com/en-us/library/cc736326.aspx
    # Reference: https://support2.microsoft.com/default.aspx?scid=kb;EN-US;321051

    # NEW: Create a new request as directed by PolicyFileIn
    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.CreateRequestCertificateMessage -f $InfPath,$ReqPath)
        ) -join '' )

    $createRequest = & certreq.exe @('-new','-q',$InfPath,$ReqPath)

    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.CreateRequestResultCertificateMessage -f $createRequest)
        ) -join '' )

    # SUBMIT: Submit a request to a Certification Authority.
    # DSC runs in the context of LocalSystem, which uses the Computer account in Active Directory
    # to authenticate to network resources
    # The Credential paramter with xPDT is used to impersonate a user making the request
    if (Test-Path -Path $ReqPath)
    {
        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.SubmittingRequestCertificateMessage -f $ReqPath,$CerPath,$CA)
                ) -join '' )

        if ($Credential)
        {
            Import-Module -Name $PSScriptRoot\..\MSFT_xPDT\MSFT_xPDT.psm1 -Force

            # Assemble the command and arguments to pass to the powershell process that
            # will request the certificate
            $CertReqOutPath = [System.IO.Path]::ChangeExtension($WorkingPath,'.out')
            $Command = "$ENV:SystemRoot\System32\WindowsPowerShell\v1.0\PowerShell.exe"
            $Arguments = "-Command ""& $ENV:SystemRoot\system32\certreq.exe" + `
                " @('-submit','-q','-config',$CA,'$ReqPath','$CerPath')" + `
                " | Set-Content -Path '$CertReqOutPath'"""

            # This may output a win32-process object, but it often does not because of
            # a timing issue in MSFT_xPDT (the process has often completed before the
            # process can be read in).
            StartWin32Process `
                -Path $Command `
                -Arguments $Arguments `
                -Credential $Credential

            Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.SubmittingRequestProcessCertificateMessage)
            ) -join '' )

            WaitForWin32ProcessEnd `
                -Path "$ENV:SystemRoot\system32\certreq.exe" `
                -Arguments $Arguments `
                -Credential $Credential

            if (Test-Path -Path $CertReqOutPath)
            {
                $submitRequest = Get-Content -Path $CertReqOutPath
                Remove-Item -Path $CertReqOutPath -Force
            }
            else
            {
                ThrowInvalidArgumentError `
                    -ErrorId 'CertReqOutNotFoundError' `
                    -ErrorMessage ($LocalizedData.CertReqOutNotFoundError -f $LogPath)
            } # if
        }
        else
        {
            $submitRequest = & certreq.exe @('-submit','-q','-config',$CA,$ReqPath,$CerPath)
        } # if

        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.SubmittingRequestResultCertificateMessage -f $submitRequest)
            ) -join '' )
    }
    else
    {
        ThrowInvalidArgumentError `
            -ErrorId 'CertificateReqNotFoundError' `
            -ErrorMessage ($LocalizedData.CertificateReqNotFoundError -f $ReqPath)
    } # if

    # ACCEPT: Accept the request
    if (Test-Path -Path $CerPath)
    {
        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.AcceptingRequestCertificateMessage -f $CerPath,$CA)
            ) -join '' )

        $acceptRequest = & certreq.exe @('-accept','-machine','-q',$CerPath)

        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.AcceptingRequestResultCertificateMessage -f $acceptRequest)
            ) -join '' )
    }
    else
    {
        ThrowInvalidArgumentError `
            -ErrorId 'CertificateCerNotFoundError' `
            -ErrorMessage ($LocalizedData.CertificateCerNotFoundError -f $CerPath)
    } # if

    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.CleaningUpRequestFilesMessage -f "$($WorkingPath).*")
        ) -join '' )
    Remove-Item -Path "$($WorkingPath).*" -Force
} # end function Set-TargetResource


function Test-TargetResource
{
    [CmdletBinding()]
    [OutputType([System.Boolean])]
    param
    (
        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $Subject,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CAServerFQDN,

        [parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CARootName,

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $KeyLength = '1024',

        [parameter(Mandatory = $false)]
        [System.Boolean]
        $Exportable = $true,

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $ProviderName = '"Microsoft RSA SChannel Cryptographic Provider""',

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $OID = '1.3.6.1.5.5.7.3.1',

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $KeyUsage = '0xa0',

        [parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [System.String]
        $CertificateTemplate = 'WebServer',

        [System.Management.Automation.PSCredential]
        $Credential,

        [System.Boolean]
        $AutoRenew
    )

    # The certificate authority, accessible on the local area network
    [System.String] $CA = "'$CAServerFQDN\$CARootName'"

    # If the Subject does not contain a full X500 path, construct just the CN
    if (($Subject.split('=').count) -eq 1)
    {
        [System.String] $Subject = "CN=$Subject"
    }

    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.TestingCertReqStatusMessage -f $Subject,$CA)
        ) -join '' )

    $Cert = Get-Childitem -Path Cert:\LocalMachine\My |
        Where-Object -FilterScript {
            $_.Subject -eq $Subject -and `
            $_.Issuer.split(',')[0] -eq "CN=$CARootName"
        }

    # If multiple certs have the same subject and were issued by the CA, return the newest
    $Cert = $Cert | Sort-Object -Property NotBefore -Descending | Select-Object -First 1

    if ($Cert)
    {
        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.CertificateExistsMessage -f $Subject,$CA,$Cert.Thumbprint)
            ) -join '' )

        if ($AutoRenew) {
            if ($Cert.NotAfter -le (Get-Date).AddDays(-30))
            {
                # The certificate was found but it is expiring within 30 days or has expired
                Write-Verbose -Message ( @(
                        "$($MyInvocation.MyCommand): "
                        $($LocalizedData.ExpiringCertificateMessage -f $Subject,$CA,$Cert.Thumbprint)
                    ) -join '' )
                return $false
            } # if
        }
        else
        {
            if ($Cert.NotAfter -le (Get-Date))
            {
                # The certificate has expired
                Write-Verbose -Message ( @(
                        "$($MyInvocation.MyCommand): "
                        $($LocalizedData.ExpiredCertificateMessage -f $Subject,$CA,$Cert.Thumbprint)
                    ) -join '' )
                return $false
            } # if
        } # if

        if (-not $Cert.Verify())
        {
            Write-Verbose -Message ( @(
                    "$($MyInvocation.MyCommand): "
                    $($LocalizedData.InvalidCertificateMessage -f $Subject,$CA,$Cert.Thumbprint)
                ) -join '' )
            return $false
        } # if

        # The certificate was found and is OK - so no change required.
        Write-Verbose -Message ( @(
                "$($MyInvocation.MyCommand): "
                $($LocalizedData.ValidCertificateExistsMessage -f $Subject,$CA,$Cert.Thumbprint)
            ) -join '' )
        return $true
    } # if

    # A valid certificate was not found
    Write-Verbose -Message ( @(
            "$($MyInvocation.MyCommand): "
            $($LocalizedData.NoValidCertificateMessage -f $Subject,$CA)
        ) -join '' )
    return $false
} # end function Test-TargetResource
