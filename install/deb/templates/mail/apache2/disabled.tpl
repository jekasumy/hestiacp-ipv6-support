<VirtualHost %ip%:%web_port% [%ip6%]:%web_port%>
    ServerName %domain_idn%
    ServerAlias %alias_idn%
    DocumentRoot /var/www/html/
    Alias /error/ /var/www/document_errors/
    #SuexecUserGroup %user% %group%
</VirtualHost>
