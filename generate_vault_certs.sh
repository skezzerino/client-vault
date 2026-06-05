#!/bin/bash

mkdir -p $CA_HOME/{root,cert}

openssl genrsa -out $CA_HOME/root/ca.key 2048
  chmod 400 $CA_HOME/root/ca.key
  openssl req -new -x509 -nodes -subj "/C=RU/ST=Msk/L=Moscow/O=ITKey/OU=KeyStack/CN=KeyStack Root CA" \
      -key $CA_HOME/root/ca.key -sha256 \
      -days 3650 -out $CA_HOME/root/ca.crt
  chmod 444 $CA_HOME/root/ca.crt
  cat $CA_HOME/root/ca.crt > $CA_HOME/cert/chain-ca.pem
  chmod 444 $CA_HOME/cert/chain-ca.pem
  for ca in $VAULT_NAME; do
    openssl genrsa -out $CA_HOME/cert/$ca.key 2048
    openssl req -new -subj "/C=RU/ST=Msk/L=Moscow/O=ITKey/OU=KeyStack/CN=$ca.$DOMAIN" \
        -key $CA_HOME/cert/$ca.key -out $CA_HOME/cert/$ca.csr
    export SAN=DNS:$ca.$DOMAIN
    openssl x509 -req -in $CA_HOME/cert/$ca.csr \
        -extfile $CA_HOME/cert.cnf -CA $CA_HOME/root/ca.crt \
        -CAkey $CA_HOME/root/ca.key -CAcreateserial \
        -out $CA_HOME/cert/$ca.crt -days 728 -sha256
    cat $CA_HOME/cert/$ca.crt $CA_HOME/root/ca.crt > $CA_HOME/cert/chain-$ca.pem
  done

mkdir -p $VAULT_HOME/{config,file,logs}

cp $CA_HOME/cert/chain-ca.pem $VAULT_HOME/config
cat $CA_HOME/root/ca.key $CA_HOME/root/ca.crt > $VAULT_HOME/config/root.pem