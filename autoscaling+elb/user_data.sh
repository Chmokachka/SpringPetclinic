#!/bin/bash                                                                     
apt update -y
apt install nginx -y
apt install maven -y
apt install default-jdk -y
apt install git -y
ufw allow 'Nginx HTTP'
git clone https://github.com/Chmokachka/SpringPetclinic.git
#sudo echo "export MY_DB=${db_url}" >> /etc/environment
sudo sed -i "s/localhost/${db_url}/g" /SpringPetclinic/src/main/resources/application-mysql.properties
chmod +x /SpringPetclinic/start
(cd /SpringPetclinic && sudo ./mvnw package)
sudo mv /SpringPetclinic/petclinic.service /usr/lib/systemd/system/
sudo systemctl daemon-reload
sudo systemctl start petclinic.service
#(cd /SpringPetclinic && sudo mvn spring-boot:start -Dspring-boot.run.profiles=mysql)