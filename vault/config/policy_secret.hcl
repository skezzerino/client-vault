path "secret_v2/data/*" {
  capabilities = ["read", "create", "patch", "update"]
}
path "installer*" {
  capabilities = ["read", "list"]
}
path "installer/roles/*" {
  capabilities = ["create", "update"]
}
path "installer/sign/*" {
  capabilities = ["create", "update"]
}
path "installer/issue/*" {
  capabilities = ["create", "update"]
}