## Install Nexus on Dev Tools Host

```bash
LAB_DOMAIN=clg.lab

dnf install -y java-17-openjdk.x86_64
mkdir -p /usr/local/nexus/home
cd /usr/local/nexus
wget https://download.sonatype.com/nexus/3/latest-unix.tar.gz -O latest-unix.tar.gz
tar -xzf latest-unix.tar.gz
NEXUS=\$(ls -d nexus-*)
ln -s \${NEXUS} nexus-3
rm -f latest-unix.tar.gz
groupadd nexus
useradd -g nexus -d /usr/local/nexus/home nexus
chown -R nexus:nexus /usr/local/nexus
sed -i "s|#run_as_user=\"\"|run_as_user=\"nexus\"|g" /usr/local/nexus/nexus-3/bin/nexus.rc
keytool -genkeypair -keystore /usr/local/nexus/nexus-3/etc/ssl/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname "CN=nexus.clg.lab, OU=clg-lab, O=clg-lab, L=City, ST=State, C=US" -ext "SAN=DNS:nexus.clg.lab,IP:10.11.12.20" -ext "BC=ca:true"

cat /usr/local/nexus/sonatype-work/nexus3/admin.password

firewall-cmd --add-port=5000/tcp --permanent
firewall-cmd --add-port=5001/tcp --permanent
firewall-cmd --add-port=5002/tcp --permanent
firewall-cmd --add-port=8443/tcp --permanent
firewall-cmd --reload

openssl s_client -showcerts -connect nexus.${LAB_DOMAIN}:8443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /etc/pki/ca-trust/source/anchors/nexus.crt
update-ca-trust extract
```

## Install KeyCloak on Dev Tools Host

```bash
LAB_DOMAIN=clg.lab

KEYCLOAK_VER=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/keycloak/keycloak/releases/latest))

mkdir -p /usr/local/keycloak
cd /usr/local/keycloak
wget -O keycloak-${KEYCLOAK_VER}.zip https://github.com/keycloak/keycloak/releases/download/${KEYCLOAK_VER}/keycloak-${KEYCLOAK_VER}.zip
unzip keycloak-${KEYCLOAK_VER}.zip
ln -s keycloak-${KEYCLOAK_VER} keycloak-server
keytool -genkeypair -keystore /usr/local/keycloak/keystore.jks -deststoretype pkcs12 -storepass password -keypass password -alias jetty -keyalg RSA -keysize 4096 -validity 5000 -dname "CN=keycloak.${LAB_DOMAIN}, OU=openshift4-lab, O=openshift4-lab, L=City, ST=State, C=US" -ext "SAN=DNS:keycloak.${LAB_DOMAIN},IP:10.11.12.20" -ext "BC=ca:true"
mv /usr/local/keycloak/keycloak-server/conf/keycloak.conf /usr/local/keycloak/keycloak-server/conf/keycloak.conf.orig
mkdir -p /usr/local/keycloak/home
groupadd keycloak
useradd -g keycloak -d /usr/local/keycloak/home keycloak

cat << EOF > /usr/local/keycloak/keycloak-server/conf/keycloak.conf
hostname=keycloak.${LAB_DOMAIN}
http-enabled=false
https-key-store-file=/usr/local/keycloak/keystore.jks
https-port=7443
bootstrap-admin-username=keycloak
bootstrap-admin-password=keycloak
EOF

firewall-cmd --add-port=7443/tcp --permanent
firewall-cmd --reload

cat << EOF > /etc/systemd/system/keycloak.service
[Unit]
Description=keycloak service
After=network.target

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/keycloak/keycloak-server/bin/kc.sh start
ExecStop=kill $(ps -x | grep keycloak | grep java | cut -d" " -f2)
User=keycloak
Restart=on-abort

[Install]
WantedBy=multi-user.target
EOF

systemctl enable keycloak.service
systemctl start keycloak.service

openssl s_client -showcerts -connect keycloak.${LAB_DOMAIN}:7443 </dev/null 2>/dev/null|openssl x509 -outform PEM > /etc/pki/ca-trust/source/anchors/keycloak.crt
update-ca-trust extract
```

## Install Gitea on Dev Tools Host

```bash
LAB_DOMAIN=clg.lab

GITEA_VERSION=$(basename $(curl -Ls -o /dev/null -w %{url_effective} https://github.com/go-gitea/gitea/releases/latest) | cut -d'v' -f2)
dnf install -y sqlite
mkdir -p /usr/local/gitea
for i in bin etc custom data db git
  do mkdir /usr/local/gitea/${i}
done
wget -O /usr/local/gitea/bin/gitea https://github.com/go-gitea/gitea/releases/download/v${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64
chmod 750 /usr/local/gitea/bin/gitea

INTERNAL_TOKEN=$(/usr/local/gitea/bin/gitea generate secret INTERNAL_TOKEN)
SECRET_KEY=$(/usr/local/gitea/bin/gitea generate secret SECRET_KEY)
JWT_SECRET=$(/usr/local/gitea/bin/gitea generate secret JWT_SECRET)

cat << EOF > /usr/local/gitea/etc/app.ini
RUN_USER = gitea
RUN_MODE = prod

[repository]
ROOT = /usr/local/gitea/git
SCRIPT_TYPE = sh
DEFAULT_BRANCH = main
DEFAULT_PUSH_CREATE_PRIVATE = true
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[server]
PROTOCOL = https
ROOT_URL = https://gitea.${LAB_DOMAIN}:3000/
HTTP_PORT = 3000
HTTP_ADDR = 0.0.0.0
CERT_FILE = cert.pem
KEY_FILE  = key.pem
STATIC_ROOT_PATH = /usr/local/gitea/web
APP_DATA_PATH    = /usr/local/gitea/data
LFS_START_SERVER = true

[service]
DISABLE_REGISTRATION = false

[database]
DB_TYPE = sqlite3
PATH = /usr/local/gitea/db/gitea.db

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${JWT_SECRET}

[session]
PROVIDER = file

[log]
ROOT_PATH = /usr/local/gitea/log
MODE = file
LEVEL = Info

[webhook]
ALLOWED_HOST_LIST = *
EOF

cat << EOF > /etc/systemd/system/gitea.service
[Unit]
Description=gitea service
After=network.target

[Service]
Type=simple
LimitNOFILE=65536
ExecStart=/usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini web
ExecStop=/usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini manager shutdown
User=gitea
Restart=on-abort
Environment="GITEA_WORK_DIR=/usr/local/gitea"

[Install]
WantedBy=multi-user.target
EOF

cd /usr/local/gitea/custom
/usr/local/gitea/bin/gitea cert --host gitea.${LAB_DOMAIN}
groupadd gitea
useradd -g gitea -d /usr/local/gitea gitea
chown -R gitea:gitea /usr/local/gitea

su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini migrate'
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --admin --username gitea --password password --email gitea@gitea.${LAB_DOMAIN} --must-change-password"
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin user create --username devuser --password password --email devuser@gitea.${LAB_DOMAIN} --must-change-password"

firewall-cmd --add-port=3000/tcp --permanent
firewall-cmd --reload
systemctl enable gitea.service
systemctl start gitea.service

openssl s_client -showcerts -connect gitea.${LAB_DOMAIN}:3000 </dev/null 2>/dev/null|openssl x509 -outform PEM > /etc/pki/ca-trust/source/anchors/gitea.crt
update-ca-trust extract
```

## Trust Certs in OCP

```bash
NEXUS_CERT=$(openssl s_client -showcerts -connect nexus.${LAB_DOMAIN}:8443 </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "    $line"; done)
KEYCLOAK_CERT=$(openssl s_client -showcerts -connect keycloak.${LAB_DOMAIN}:7443 </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "    $line"; done)
GITEA_CERT=$(openssl s_client -showcerts -connect gitea.${LAB_DOMAIN}:3000 </dev/null 2>/dev/null|openssl x509 -outform PEM | while read line; do echo "    $line"; done)
```

```bash
cat << EOF | oc apply -n openshift-config -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: lab-ca
data:
  ca-bundle.crt: |
    # Nexus Cert
${NEXUS_CERT}
    # KeyCloak Cert
${KEYCLOAK_CERT}
    # Gitea Cert
${GITEA_CERT}
EOF
```

```bash
oc patch proxy cluster --type=merge --patch '{"spec":{"trustedCA":{"name":"lab-ca"}}}'
```


## Gitea With KeyCloak

```bash
cat << EOF > /usr/local/gitea/etc/app.ini
RUN_USER = gitea
RUN_MODE = prod

[repository]
ROOT = /usr/local/gitea/git
SCRIPT_TYPE = sh
DEFAULT_BRANCH = main
DEFAULT_PUSH_CREATE_PRIVATE = true
ENABLE_PUSH_CREATE_USER = true
ENABLE_PUSH_CREATE_ORG = true

[server]
PROTOCOL = https
ROOT_URL = https://gitea.${LAB_DOMAIN}:3000/
HTTP_PORT = 3000
HTTP_ADDR = 0.0.0.0
CERT_FILE = cert.pem
KEY_FILE  = key.pem
STATIC_ROOT_PATH = /usr/local/gitea/web
APP_DATA_PATH    = /usr/local/gitea/data
LFS_START_SERVER = true

[service]
DISABLE_REGISTRATION = false
ENABLE_PASSWORD_SIGNIN_FORM = false
ENABLE_BASIC_AUTHENTICATION = false

[database]
DB_TYPE = sqlite3
PATH = /usr/local/gitea/db/gitea.db

[security]
INSTALL_LOCK = true
SECRET_KEY = ${SECRET_KEY}
INTERNAL_TOKEN = ${INTERNAL_TOKEN}

[oauth2]
JWT_SECRET = ${JWT_SECRET}
ENABLE_AUTO_REGISTRATION = true
USERNAME = userid

[session]
PROVIDER = file

[log]
ROOT_PATH = /usr/local/gitea/log
MODE = file
LEVEL = Info

[webhook]
ALLOWED_HOST_LIST = *
EOF
```

```bash
su - gitea -c 'GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini migrate'
su - gitea -c "GITEA_WORK_DIR=/usr/local/gitea /usr/local/gitea/bin/gitea --config /usr/local/gitea/etc/app.ini admin add-oauth --name clg-lab-gitea --provider oidc --key ${GITEA_CLIENT_KEY} --secret ${GITEA_CLIENT_SECRET} --auto-discover-url https://keycloak.clg.lab:7443/realms/clg-lab/.well-known/openid-configuration --group-claim-name groups --admin-group lab-admin "
```