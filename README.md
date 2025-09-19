testing
If execution policy is set to signed, don't download scripts, paste them into ps.
For proxy, ``HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Internet Settings``, ``ProxyEnable`` should be set to 1, ``ProxyServer`` should be set to 127.0.0.1:3000

This can be done through regedit, or paste 

```Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyEnable -Value 1; Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -Name ProxyServer -Value "127.0.0.1:3000"``` 

into powershell
