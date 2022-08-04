# Nginx
Edit root with the address of your website, example: root /var/www/domain.com

Add your website in the server_name line, example: server_name dominio.com www.dominio.comAdd the .sock file to be able to run PHP, edit the line: fastcgi_pass unix:

It is usually located at the following address: /var/run/php/ph-fpm.sock;
Install php-fpm with the following command: apt install php-fpm.
