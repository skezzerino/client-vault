####################
# * Certificates * #
####################
mkdir -p $CA_HOME/{root,cert}

function gencrt() {
  cp cert.cnf $CFG_HOME
  openssl genrsa -out $CA_HOME/root/ca.key 2048
  chmod 400 $CA_HOME/root/ca.key
  openssl req -new -x509 -nodes -subj "/C=RU/ST=Msk/L=Moscow/O=ITKey/OU=KeyStack/CN=KeyStack Root CA" \
      -key $CA_HOME/root/ca.key -sha256 \
      -days 3650 -out $CA_HOME/root/ca.crt
  chmod 444 $CA_HOME/root/ca.crt
  cat $CA_HOME/root/ca.crt > $CA_HOME/cert/chain-ca.pem
  chmod 444 $CA_HOME/cert/chain-ca.pem
  for ca in $NEXUS_NAME $GITLAB_NAME $VAULT_NAME $NETBOX_NAME; do
    openssl genrsa -out $CA_HOME/cert/$ca.key 2048
    openssl req -new -subj "/C=RU/ST=Msk/L=Moscow/O=ITKey/OU=KeyStack/CN=$ca.$DOMAIN" \
        -key $CA_HOME/cert/$ca.key -out $CA_HOME/cert/$ca.csr
    export SAN=DNS:$ca.$DOMAIN
    openssl x509 -req -in $CA_HOME/cert/$ca.csr \
        -extfile $CFG_HOME/cert.cnf -CA $CA_HOME/root/ca.crt \
        -CAkey $CA_HOME/root/ca.key -CAcreateserial \
        -out $CA_HOME/cert/$ca.crt -days 728 -sha256
    cat $CA_HOME/cert/$ca.crt $CA_HOME/root/ca.crt > $CA_HOME/cert/chain-$ca.pem
  done
}




#######################
# * Hashicorp Vault * #
#######################
mkdir -p $VAULT_HOME/{config,file,logs}
cp vault.json $VAULT_HOME/config
cp policy_secret.hcl $VAULT_HOME/config
cp $CA_HOME/cert/chain-ca.pem $VAULT_HOME/config
if [[ $SELF_SIG == "y" ]]; then
  cat $CA_HOME/root/ca.key $CA_HOME/root/ca.crt > $VAULT_HOME/config/root.pem
else
  openssl genrsa -out /tmp/ca.key 2048
  chmod 400 /tmp/ca.key
  openssl req -new -x509 -nodes -subj "/C=RU/ST=Msk/L=Moscow/O=ITKey/OU=KeyStack/CN=KeyStack Root CA" \
      -key /tmp/ca.key -sha256 \
      -days 3650 -out /tmp/ca.crt
  chmod 444 /tmp/ca.crt
  cat /tmp/ca.key /tmp/ca.crt > $VAULT_HOME/config/root.pem
  rm -f /tmp/ca.*
fi


# Nginx settings
mkdir -p $NGINX_HOME/conf.d/certs
cp nginx.conf $NGINX_HOME
sed -i "s/DOMAIN/$DOMAIN/g" $NGINX_HOME/nginx.conf
sed -i "s/NEXUS_NAME/$NEXUS_NAME/g" $NGINX_HOME/nginx.conf
sed -i "s/GITLAB_NAME/$GITLAB_NAME/g" $NGINX_HOME/nginx.conf
sed -i "s/VAULT_NAME/$VAULT_NAME/g" $NGINX_HOME/nginx.conf
sed -i "s/NETBOX_NAME/$NETBOX_NAME/g" $NGINX_HOME/nginx.conf

for ca in $NEXUS_NAME $GITLAB_NAME $VAULT_NAME $NETBOX_NAME; do
  cp $CA_HOME/cert/chain-$ca.pem $NGINX_HOME/conf.d/certs/chain-$ca.pem
  cp $CA_HOME/cert/$ca.key $NGINX_HOME/conf.d/certs/$ca.key
done


# Vault unseal and add passwords, kv
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault operator init -key-shares=1 -key-threshold=1 > /vault/config/unseal_info"
for key in $($DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault cat /vault/config/unseal_info | grep "Unseal Key" | awk '{print $4}'); do $DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault vault operator unseal $key; done
for key in $($DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault cat /vault/config/unseal_info | grep "Initial Root" | awk '{print $4}'); do $DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault vault login -no-print $key; done
Unseal_Key=$(cat $VAULT_HOME/config/unseal_info | grep "Unseal Key" | awk '{print $4}')
Root_Token=$(cat $VAULT_HOME/config/unseal_info | grep "Initial Root" | awk '{print $4}')


$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault auth enable approle"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault secrets enable -path=secret_v2 -version 2 kv"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault policy write secret_v2/deployments /vault/config/policy_secret.hcl"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault write auth/approle/role/keystack token_type=batch token_policies=secret_v2/deployments"
role_id=$($DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault read -field=role_id auth/approle/role/keystack/role-id")
secret_id=$($DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault write -f -field=secret_id auth/approle/role/keystack/secret-id")

$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault kv put -mount=secret_v2 deployments/$GITLAB_NAME.$DOMAIN/secrets/job_key value=\"$(<$CFG_HOME/gitlab_key)\""
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault kv put -mount=secret_v2 deployments/$GITLAB_NAME.$DOMAIN/secrets/ca.crt value=\"$(<$CA_HOME/cert/chain-ca.pem)\""
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault kv put -mount=secret_v2 deployments/$GITLAB_NAME.$DOMAIN/bifrost/rmi user="itkey" password="r00tme""
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault secrets enable -path installer pki"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault secrets tune -max-lease-ttl=43800h installer"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault write installer/config/ca pem_bundle=@vault/config/root.pem"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault write installer/roles/certs allowed_domains="$DOMAIN" allow_subdomains=true max_ttl=17520h ttl=17520h"
$DOCKER_COMPOSE_COMMAND -f $CFG_HOME/compose.yaml exec vault /bin/sh -c "vault write installer/config/urls issuing_certificates="https://$VAULT_NAME.$DOMAIN/v1/pki/ca"  crl_distribution_points="https://$VAULT_NAME.$DOMAIN/v1/pki/crl""
rm -f $VAULT_HOME/config/root.pem


#project_k Vault configuration
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_addr" -F "value=https://$VAULT_NAME.$DOMAIN" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_engine" -F "value=secret_v2" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_method" -F "value=approle" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_username" -F "value=$role_id" -F "masked=true" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_password" -F "value=$secret_id" -F "masked=true" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_prefix" -F "value=deployments/$GITLAB_NAME.$DOMAIN" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_role" -F "value=keystack" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_pki" -F "value=installer" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_role_pki" -F "value=certs" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq
curl -sX POST -H "Authorization: Bearer $token" -F "key=vault_secman" -F "value=false" "https://$GITLAB_NAME.$DOMAIN/api/v4/groups/${group_id_project_k}/variables" | jq



# -- Vault PKI (внешний Vault как CA backend для cert-manager)
# vault_pki_enabled: false — использовать self-signed CA (по умолчанию)
# vault_pki_enabled: true  — использовать внешний Vault PKI
vault_pki_enabled: false
vault_pki_server: "https://vault.example.com"
vault_pki_path: "pki_int/sign/cert-manager"
# Корневой CA Vault PKI (CN=LCM Root CA); PEM-файл рядом с lcm-config.yaml.
# Получить: curl -sk https://<vault-host>/v1/<mount>/ca/pem > vault-pki-ca.pem
vault_pki_ca_bundle_file: "vault-pki-ca.pem"
# CA, которым подписан TLS-сертификат HTTPS-эндпоинта Vault-сервера; пусто если публичный CA.
# Получить: openssl s_client -showcerts -connect <vault-host>:443 </dev/null 2>/dev/null \
#   | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' | awk '/BEGIN CERTIFICATE/{n++} n>1' \
#   > vault-server-ca.pem
vault_pki_server_ca_bundle_file: ""
vault_pki_approle_role_id: "<role-id>"  # role-id AppRole; secret-id — в K8s Secret vault-pki-approle
vault_pki_namespace: ""  # Vault Enterprise namespace; пусто для OSS/Community Edition