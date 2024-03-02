#!/bin/bash

yum update -y
yum install httpd -y
systemctl start httpd
systemctl enable httpd
echo "<h1>Hello, this is test environment instance: $(hostname -f)</h1>" >> /var/www/html/index.html