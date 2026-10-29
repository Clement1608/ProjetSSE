@{
   
    OutputDir    = 'output'

    Notification = @{
        Enabled       = $true                 
        SmtpServer    = 'smtp.gmail.com'            
        Port          = 587                     
        UseSsl        = $true
        From          = 'jonatha120809@gmail.com'
        To            = 'jonatha120809@gmail.com'
        UseCredential = $true                 
    }
}
