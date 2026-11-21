#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO=${1:-keycloak}
FAIL_AT=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
MIGRATE=$HERE/../migrate.sh
CACHE=${CACHE:-$HOME/.cache/osie-migrate-test}
KIND_VERSION=${KIND_VERSION:-v0.31.0}
CHART_VERSION=${CHART_VERSION:-26.8.2}
START_CHART=${START_CHART:-$CHART_VERSION}
NEW_CHART=${NEW_CHART:-}
HELM_BIN=${HELM_BIN:-helm}
TARGET_CONTEXT=${TARGET_CONTEXT:-}
NS=${NS:-osie}
REL=${REL:-osie}
HOST=${HOST:-osie.test}
BUNDLED_STORAGE_CLASS=${BUNDLED_STORAGE_CLASS:-}
NEW_STORAGE_CLASS=${NEW_STORAGE_CLASS:-}
unset STORAGE_CLASS
CLUSTER=osie-mig-$SCENARIO${SUFFIX:+-$SUFFIX}${FAIL_AT:+-$FAIL_AT}
CLUSTER=${CLUSTER:0:45}
[[ -z $TARGET_CONTEXT ]] || CLUSTER=remote-$NS
CTX=${TARGET_CONTEXT:-kind-$CLUSTER}
PORT=${PORT:-18080}
RUN=$CACHE/$CLUSTER
OTP_SECRET=12345678901234567890
USER_EMAIL=alice@osie.test
USER_PASSWORD='Alice-Passw0rd!'
PASSES=0
FAILS=0

[[ -n ${OSIE_LICENSE_KEY:-} ]] || { echo "Set OSIE_LICENSE_KEY to a license key for osie-api." >&2; exit 2; }
[[ $SCENARIO == keycloak || $SCENARIO == local || $SCENARIO == standalone || ($SCENARIO == existing && -n $TARGET_CONTEXT) ]] \
  || { echo "usage: rehearse.sh keycloak|local|standalone [fail-after-step], or TARGET_CONTEXT=<context> rehearse.sh keycloak|local|existing" >&2; exit 2; }
if [[ $SCENARIO == standalone ]]; then
  NS=${KC_NS:-auth} REL=${KC_REL:-auth}
fi
KC_CHART_VERSION=${KC_CHART_VERSION:-16.1.7}
KC_FULL=$REL-keycloak
[[ $REL != *keycloak* ]] || KC_FULL=$REL

trap 'echo "rehearse.sh stopped at line $LINENO: $BASH_COMMAND" >&2' ERR

say() { printf '\n\e[1m== %s\e[0m\n' "$*"; }
pass() { PASSES=$((PASSES + 1)); printf '  \e[32mPASS\e[0m %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf '  \e[31mFAIL\e[0m %s\n' "$*"; }
check() { local what=$1; shift; if "$@"; then pass "$what"; else fail "$what"; fi; }

IMAGES=(
  docker.io/bitnamilegacy/keycloak-config-cli:5.8.0-debian-11-r57
  docker.io/bitnamilegacy/keycloak:22.0.3-debian-11-r14
  docker.io/bitnamilegacy/mongodb:7.0.6-debian-12-r0
  docker.io/bitnamilegacy/postgresql:15.4.0-debian-11-r45
  docker.io/bitnamilegacy/rabbitmq:3.13.7-debian-12-r2
  docker.io/library/rabbitmq:4.2.6-management
  docker.io/library/traefik:v3.7.19
  docker.io/percona/percona-server-mongodb-operator:1.22.0
  docker.io/percona/percona-server-mongodb:7.0.18-11
  ghcr.io/cloudnative-pg/cloudnative-pg:1.30.2
  ghcr.io/cloudnative-pg/postgresql:17
  ghcr.io/osie-io/osie-keywind:0.1.0-rc1
  ghcr.io/osie/osie-admin:$CHART_VERSION
  ghcr.io/osie/osie-api:$CHART_VERSION
  ghcr.io/osie/osie-ui:$CHART_VERSION
  ghcr.io/rabbitmq/cluster-operator:2.21.0
  quay.io/keycloak/keycloak-operator:26.8.2
  quay.io/keycloak/keycloak:26.8.2
)

mkdir -p "$CACHE" "$RUN"
if [[ -n $TARGET_CONTEXT ]]; then
  (umask 077 && kubectl config view --raw --minify --context "$TARGET_CONTEXT" >"$RUN/kubeconfig")
fi
export KUBECONFIG=$RUN/kubeconfig
KIND=$CACHE/kind-$KIND_VERSION
k() { kubectl -n "$NS" "$@"; }
h() { "$HELM_BIN" "$@"; }
mig() { HELM="$HELM_BIN" KUBECONFIG=$RUN/kubeconfig.elsewhere bash "$MIGRATE" "$@"; }
migrate_args() {
  MIGRATE_ARGS=(--context "$CTX" --release "$REL" --namespace "$NS" --yes)
  [[ $SCENARIO == standalone ]] || MIGRATE_ARGS+=(--values "$RUN/customer-values.yaml")
  [[ -z $NEW_STORAGE_CLASS ]] || MIGRATE_ARGS+=(--storage-class "$NEW_STORAGE_CLASS")
}

install_standalone_keycloak() {
  say "Bitnami Keycloak $KC_CHART_VERSION as its own release $REL in $NS, with the osie theme"
  local tls=''
  [[ -z $TARGET_CONTEXT ]] || tls=$'  tls: true\n  annotations:\n    cert-manager.io/cluster-issuer: letsencrypt\n'
  cat >"$RUN/keycloak-values.yaml" <<EOF
image:
  repository: bitnamilegacy/keycloak
auth:
  adminUser: osie_admin
postgresql:
  image:
    repository: bitnamilegacy/postgresql
${BUNDLED_STORAGE_CLASS:+global:
  storageClass: $BUNDLED_STORAGE_CLASS}
keycloakConfigCli:
  enabled: false
ingress:
  enabled: true
  hostname: auth.$HOST
  ingressClassName: traefik
${tls}extraEnvVars:
  - name: KEYCLOAK_PRODUCTION
    value: "true"
  - name: KEYCLOAK_PROXY
    value: "edge"
initContainers: |-
  - name: osie-keywind-theme
    image: ghcr.io/osie-io/osie-keywind:0.1.0-rc1
    command: [sh, -c, "cp -R /theme/* /keycloak-theme"]
    volumeMounts:
      - name: keycloak-theme
        mountPath: /keycloak-theme
extraVolumeMounts: |-
  - name: keycloak-theme
    mountPath: /opt/bitnami/keycloak/themes/osie
extraVolumes: |-
  - name: keycloak-theme
    emptyDir: {}
EOF
  h install "$REL" oci://registry-1.docker.io/bitnamicharts/keycloak --version "$KC_CHART_VERSION" -n "$NS" --create-namespace \
    -f "$RUN/keycloak-values.yaml" --wait --timeout 15m >/dev/null
  [[ -z $TARGET_CONTEXT ]] || k wait --for=condition=Ready certificate --all --timeout=10m >/dev/null
  k get pods
}

seed_standalone() {
  say "seed: realm clients with the osie theme, a user with a password and OTP"
  local at
  at=$(admin_token)
  auth -o /dev/null -w '  realm %{http_code}\n' -X POST "$AUTH_URL/admin/realms" -H "Authorization: Bearer $at" -H 'Content-Type: application/json' -d \
    "{\"realm\":\"clients\",\"enabled\":true,\"loginTheme\":\"osie\",\"clients\":[{\"clientId\":\"osie-ui\",\"publicClient\":true,\"directAccessGrantsEnabled\":true,\"standardFlowEnabled\":true,\"redirectUris\":[\"${PUBLIC_URL}*\"]}]}"
  seed_user "$at"
  kc_sub >"$RUN/user.sub"
  [[ -s $RUN/user.sub ]] || { echo "no token for the seeded user" >&2; return 1; }
  echo "  Keycloak user $(cat "$RUN/user.sub")"
}

kc_sub() {
  local r at
  sleep $(( 31 - $(date +%s) % 30 ))
  r=$(user_token)
  at=$(field '["access_token"]' <<<"$r" 2>/dev/null) || return 1
  python3 -c 'import base64,json,sys; p=sys.argv[1].split(".")[1]; print(json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))["sub"])' "$at"
}

kc_same_user() { [[ $(kc_sub) == "$(cat "$RUN/user.sub")" ]]; }
bitnami_keycloak_running() { [[ -n $(k get pod -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/name=keycloak" --field-selector=status.phase=Running -o name) ]]; }

after_success_standalone() {
  say "after migration"
  forward
  check "the Keycloak user signs in with the old password and OTP, and is the same user" kc_same_user
  check "a wrong OTP is refused" wrong_otp_refused
  check "the login page uses the osie theme" login_page_has_theme
  check "the Bitnami release is uninstalled, its history kept" bash -c "[[ \$($HELM_BIN status $REL -n $NS -o json | grep -o '\"status\":\"[a-z-]*\"' | sed -n 1p) == '\"status\":\"uninstalled\"' ]]"
  check "its Service and Ingress stay" bash -c "kubectl -n $NS get svc $KC_FULL >/dev/null && kubectl -n $NS get ingress $KC_FULL >/dev/null"
  check "keycloak.$REL.yaml applies as it is, theme included" service_files_apply_as_is
  check "installing the Bitnami release again is refused and changes nothing" bash -c \
    "! $HELM_BIN upgrade --install $REL oci://registry-1.docker.io/bitnamicharts/keycloak --version $KC_CHART_VERSION -n $NS -f $RUN/keycloak-values.yaml >$RUN/reinstall.log 2>&1 && grep -q -E 'PASSWORDS ERROR|cannot be imported|cannot re-use' $RUN/reinstall.log && [[ -z \$(kubectl -n $NS get sts -l app.kubernetes.io/instance=$REL -o name) ]]"
}

after_rollback_standalone() {
  say "after rollback"
  forward
  check "the Bitnami release is deployed again" bash -c "[[ \$($HELM_BIN status $REL -n $NS -o json | grep -o '\"status\":\"[a-z-]*\"' | sed -n 1p) == '\"status\":\"deployed\"' ]]"
  check "the Bitnami Keycloak runs again" bitnami_keycloak_running
  check "new services and markers are gone" new_services_gone
  check "operators and their CRDs stay installed" operators_kept
  check "volume reclaim policies are back" pv_policies_restored
  check "keycloak.$REL.yaml is removed" service_files_removed
  check "the Keycloak user still signs in and is the same user" kc_same_user
  check "the login page uses the osie theme" login_page_has_theme
}

ensure_storage_class() {
  [[ -n $NEW_STORAGE_CLASS ]] || return 0
  kubectl get storageclass "$NEW_STORAGE_CLASS" >/dev/null 2>&1 && return 0
  kubectl apply -f - >/dev/null <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: $NEW_STORAGE_CLASS
provisioner: $(kubectl get storageclass standard -o jsonpath='{.provisioner}')
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
EOF
}

if [[ -n $TARGET_CONTEXT ]]; then
  APP_URL=https://$HOST AUTH_URL=https://auth.$HOST APP_HDR=() AUTH_HDR=()
else
  APP_URL=http://127.0.0.1:$PORT AUTH_URL=http://127.0.0.1:$PORT APP_HDR=(-H "Host: $HOST") AUTH_HDR=(-H "Host: auth.$HOST")
fi
PUBLIC_URL=${APP_URL/127.0.0.1:$PORT/$HOST}/

tools() {
  if [[ -n ${HELM_VERSION:-} ]]; then
    HELM_BIN=$CACHE/helm-$HELM_VERSION
    [[ -x $HELM_BIN ]] || { curl -fsSL "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" | tar -xzO linux-amd64/helm >"$HELM_BIN.tmp" && chmod +x "$HELM_BIN.tmp" && mv "$HELM_BIN.tmp" "$HELM_BIN"; }
    "$HELM_BIN" version --short
  fi
  if [[ ! -x $KIND ]]; then
    curl -fsSL -o "$KIND" "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-amd64"
    chmod +x "$KIND"
  fi
}

cluster() {
  say "kind cluster $CLUSTER"
  "$KIND" delete cluster --name "$CLUSTER" >/dev/null 2>&1 || true
  if [[ ${BUNDLED_HA:-0} == 1 ]]; then
    printf 'kind: Cluster\napiVersion: kind.x-k8s.io/v1alpha4\nnodes:\n- role: control-plane\n- role: worker\n- role: worker\n- role: worker\n' >"$RUN/kind.yaml"
    "$KIND" create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --config "$RUN/kind.yaml" --wait 180s
  else
    "$KIND" create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s
  fi
  printf '%s\n' "${IMAGES[@]}" | xargs -P 8 -I{} sh -c 'docker image inspect {} >/dev/null 2>&1 || docker pull -q {} >/dev/null' || true
  local node
  for node in $("$KIND" get nodes --name "$CLUSTER"); do
    printf '%s\n' "${IMAGES[@]}" | xargs -P 4 -I{} sh -c \
      "docker save {} | docker exec -i $node ctr -n k8s.io images import --platform linux/amd64 - >/dev/null 2>&1 || echo '  could not preload {} on $node'" || true
  done
  h upgrade --install traefik traefik --repo https://traefik.github.io/charts -n traefik --create-namespace \
    --set service.spec.type=ClusterIP --set ingressClass.isDefaultClass=true --wait --timeout 5m >/dev/null
  local ip corefile
  ip=$(kubectl -n traefik get svc traefik -o jsonpath='{.spec.clusterIP}')
  corefile=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')
  corefile=$(sed "s|^\(\s*\)forward |\1hosts {\n\1  $ip auth.osie.test osie.test\n\1  fallthrough\n\1}\n\1forward |" <<<"$corefile")
  kubectl -n kube-system create cm coredns --from-literal=Corefile="$corefile" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n kube-system rollout restart deploy/coredns >/dev/null
  kubectl -n kube-system rollout status deploy/coredns --timeout=2m >/dev/null
}

install_osie() {
  say "osie $START_CHART with bundled services ($SCENARIO)"
  {
    printf 'global:\n'
    [[ -z $BUNDLED_STORAGE_CLASS ]] || printf '  storageClass: %s\n' "$BUNDLED_STORAGE_CLASS"
    printf '  ingress:\n    enabled: true\n    hostname: %s\n    ingressClassName: traefik\n' "$HOST"
    [[ -z $TARGET_CONTEXT ]] || printf '    tls: true\n    annotations:\n      cert-manager.io/cluster-issuer: letsencrypt\n'
    printf 'license:\n  key: "%s"\n' "$OSIE_LICENSE_KEY"
    [[ $SCENARIO != local ]] || printf 'keycloak:\n  enabled: false\n'
    [[ ${BUNDLED_HA:-0} != 1 ]] || printf 'mongodb:\n  architecture: replicaset\n  replicaCount: 3\nrabbitmq:\n  replicaCount: 3\n'
    [[ -z ${BIG_DATA_GB:-} ]] || printf 'mongodb:\n  persistence:\n    size: %sGi\n' $((BIG_DATA_GB * 2))
    [[ ${EXTRA_THEME:-0} != 1 ]] || cat <<'EOF'
keycloak:
  initContainers: |-
    - name: osie-keywind-theme
      image: ghcr.io/osie-io/osie-keywind:0.1.0-rc1
      command: [sh, -c, "cp -R /theme/* /keycloak-theme"]
      volumeMounts:
        - name: keycloak-theme
          mountPath: /keycloak-theme
    - name: unrelated-check
      image: ghcr.io/osie-io/osie-keywind:0.1.0-rc1
      command: [sh, -c, "true"]
  extraVolumeMounts: |-
    - name: keycloak-theme
      mountPath: /opt/bitnami/keycloak/themes/osie
    - name: extra-theme
      mountPath: /opt/bitnami/keycloak/themes/extra
  extraVolumes: |-
    - name: keycloak-theme
      emptyDir: {}
    - name: extra-theme
      configMap:
        name: rehearsal-theme
        items:
          - {key: theme.properties, path: login/theme.properties}
EOF
  } >"$RUN/values.yaml"
  if [[ ${EXTRA_THEME:-0} == 1 ]]; then
    kubectl create namespace "$NS" >/dev/null 2>&1 || true
    k create configmap rehearsal-theme --from-literal=theme.properties='parent=base' --dry-run=client -o yaml | k apply -f - >/dev/null
  fi
  h install "$REL" osie --repo https://helm.osie.io --version "$START_CHART" -n "$NS" --create-namespace \
    -f "$RUN/values.yaml" --wait --timeout 20m >/dev/null
  [[ -z $TARGET_CONTEXT ]] || k wait --for=condition=Ready certificate --all --timeout=10m >/dev/null
  k get pods
}

release_chart() { h list -n "$NS" -f "^$REL\$" -o json | grep -o '"chart":"osie-[^"]*"' | sed 's/.*osie-//; s/"$//'; }
release_revision() { h history "$REL" -n "$NS" --max 1 -o json | grep -o '"revision":[0-9]*' | sed 's/.*://'; }

upgrade_first() {
  local from
  from=$(release_chart)
  say "chart $from: refused, then upgraded to $CHART_VERSION"
  check "migrate.sh refuses chart $from and changes nothing" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN bash $MIGRATE plan --context $CTX --release $REL --namespace $NS >$RUN/old-chart.log 2>&1 && grep -q 'Upgrade OSIE to chart' $RUN/old-chart.log && ! ls -d $RUN/osie-migration-* >/dev/null 2>&1"
  local ssa=()
  [[ $(h version --short) == v3* ]] || ssa=(--server-side=false)
  h upgrade "$REL" osie --repo https://helm.osie.io --version "$CHART_VERSION" -n "$NS" --reset-then-reuse-values \
    "${ssa[@]}" --set-string "license.key=$OSIE_LICENSE_KEY" --wait --timeout 20m >/dev/null
  check "osie-api healthy on chart $CHART_VERSION" wait_api
}

new_chart_refuses() {
  local rev pvcs
  rev=$(release_revision)
  pvcs=$(k get pvc -o name | sort)
  check "the chart without bundled services refuses a --reuse-values upgrade" bash -c \
    "! $HELM_BIN upgrade $REL $NEW_CHART -n $NS --reuse-values >$RUN/new-chart-reuse.log 2>&1 && grep -q 'still runs the bundled' $RUN/new-chart-reuse.log"
  check "the chart without bundled services refuses an upgrade with the values file" bash -c \
    "! $HELM_BIN upgrade $REL $NEW_CHART -n $NS -f $RUN/values.yaml >$RUN/new-chart-values.log 2>&1 && grep -q 'still runs the bundled' $RUN/new-chart-values.log"
  check "the refused upgrades changed nothing" bash -c \
    "[[ \$($HELM_BIN history $REL -n $NS --max 1 -o json | grep -o '\"revision\":[0-9]*' | sed 's/.*://') == $rev && \$(kubectl -n $NS get pvc -o name | sort) == '$pvcs' ]]"
  check "the bundled services still run" bundled_running
}

new_chart_upgrades() {
  say "upgrade to the chart without bundled services"
  check "the migrated release upgrades to the chart without bundled services with its values file" bash -c \
    "$HELM_BIN upgrade $REL $NEW_CHART -n $NS -f $RUN/customer-values.yaml --wait --timeout 20m >$RUN/new-chart-upgrade.log 2>&1"
  check "osie-api healthy on the new chart" wait_api
  if [[ $SCENARIO == keycloak ]]; then
    check "the Keycloak user signs in on the new chart" user_still_signs_in
  else
    check "onboarding stays done on the new chart" onboarding_done
  fi
  check "migrate.sh finds nothing to move on the new chart" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN bash $MIGRATE plan --context $CTX --release $REL --namespace $NS --values $RUN/customer-values.yaml >$RUN/new-chart-plan.log 2>&1 && grep -q 'nothing to move' $RUN/new-chart-plan.log"
  check "rollback refuses once the release moved on" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN KUBECONFIG=$RUN/kubeconfig.elsewhere bash $MIGRATE rollback --yes >$RUN/rollback-moved-on.log 2>&1 && grep -q 'changed after the migration' $RUN/rollback-moved-on.log"
}

old_volumes_gone() {
  local n
  for _ in $(seq 36); do
    n=$(k get pvc -o name | grep -c -E "/($REL-mongodb|datadir-$REL-mongodb-[0-9]+|data-$REL-rabbitmq-[0-9]+|data-$REL-postgresql-0)\$" || true)
    ((n == 0)) && return 0
    sleep 5
  done
  return 1
}

after_cleanup() {
  say "migrate.sh cleanup"
  check "cleanup succeeded" bash -c "cd $RUN && HELM=$HELM_BIN KUBECONFIG=$RUN/kubeconfig.elsewhere bash $MIGRATE cleanup --yes >$RUN/cleanup.log 2>&1"
  check "the old volumes are deleted" old_volumes_gone
  if [[ $SCENARIO == standalone ]]; then
    check "the Keycloak user still signs in" kc_same_user
  else
    check "osie-api stays healthy" wait_api
  fi
  check "rollback refuses after cleanup" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN KUBECONFIG=$RUN/kubeconfig.elsewhere bash $MIGRATE rollback --yes >$RUN/rollback-after-cleanup.log 2>&1 && grep -q -E 'Cleanup already deleted|changed after the migration' $RUN/rollback-after-cleanup.log"
}

forward() {
  [[ -z $TARGET_CONTEXT ]] || return 0
  pkill -f "port-forward.*svc/traefik $PORT:80" 2>/dev/null || true
  kubectl -n traefik port-forward svc/traefik "$PORT:80" >"$RUN/port-forward.log" 2>&1 &
  for _ in $(seq 30); do curl -s -o /dev/null "http://127.0.0.1:$PORT/" && return 0; sleep 1; done
  return 1
}

totp() {
  python3 - "$OTP_SECRET" <<'EOF'
import hmac, hashlib, struct, sys, time
key = sys.argv[1].encode()
msg = struct.pack(">Q", int(time.time()) // 30)
d = hmac.new(key, msg, hashlib.sha1).digest()
o = d[-1] & 15
print("%06d" % ((struct.unpack(">I", d[o:o + 4])[0] & 0x7fffffff) % 1000000))
EOF
}

auth() { curl -s "${AUTH_HDR[@]}" "$@"; }
api() { curl -s "${APP_HDR[@]}" "$@"; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }

admin_token() {
  local pw
  pw=$(k get secret "$KC_FULL" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
  [[ -n $pw ]] || pw=$(cat "$RUN/kc-admin-password")
  printf '%s' "$pw" >"$RUN/kc-admin-password"
  auth -X POST "$AUTH_URL/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=osie_admin --data-urlencode "password=$pw" | field '["access_token"]'
}

user_token() {
  local code=${1:-$(totp)}
  auth -X POST "$AUTH_URL/realms/clients/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=osie-ui -d scope=openid -d "username=$USER_EMAIL" \
    --data-urlencode "password=$USER_PASSWORD" -d "totp=$code"
}

seed_user() {
  local body
  body=$(cat <<EOF
{"username":"$USER_EMAIL","email":"$USER_EMAIL","emailVerified":true,"enabled":true,"firstName":"Alice","lastName":"Migrate",
 "credentials":[{"type":"password","value":"$USER_PASSWORD","temporary":false},
  {"type":"otp","userLabel":"phone","secretData":"{\"value\":\"$OTP_SECRET\"}","credentialData":"{\"subType\":\"totp\",\"digits\":6,\"counter\":0,\"period\":30,\"algorithm\":\"HmacSHA1\"}"}]}
EOF
)
  auth -o /dev/null -w '  user %{http_code}\n' -X POST "$AUTH_URL/admin/realms/clients/users" -H "Authorization: Bearer $1" -H 'Content-Type: application/json' -d "$body"
}

seed_keycloak() {
  say "seed: a Keycloak user with a password and OTP, signed in to OSIE once"
  seed_user "$(admin_token)"
  sign_in "$RUN/user.before.json" || { echo "no user token" >&2; return 1; }
  user_id "$RUN/user.before.json" >"$RUN/user.id"
  [[ -s $RUN/user.id ]] || { cat "$RUN/user.before.json" >&2; return 1; }
  echo "  OSIE user id $(cat "$RUN/user.id")"
}

seed_local() {
  say "seed: onboard a local admin in osie-api"
  api -X POST -H 'Content-Type: application/json' "$APP_URL/api-v1/admin/onboarding/initialize-user" \
    -d "{\"email\":\"admin@osie.test\",\"firstname\":\"Ada\",\"lastname\":\"Admin\",\"password\":\"$USER_PASSWORD\",\"passwordConfirmation\":\"$USER_PASSWORD\"}" -o /dev/null -w '  initialize-user %{http_code}\n'
  api -X POST -H 'Content-Type: application/json' "$APP_URL/api-v1/admin/onboarding/platform-configuration" -d '{"name":"Rehearsal"}' -o /dev/null -w '  platform %{http_code}\n'
  api -X POST -H 'Content-Type: application/json' "$APP_URL/api-v1/admin/onboarding/billing-configuration" \
    -d '{"companyName":"Rehearsal SRL","country":"RO","city":"Iasi","address":"Str. 1","currency":"EUR"}' -o /dev/null -w '  billing %{http_code}\n'
}

sign_in() {
  local r at it
  sleep $(( 31 - $(date +%s) % 30 ))
  r=$(user_token)
  at=$(field '["access_token"]' <<<"$r" 2>/dev/null) || return 1
  it=$(field '["id_token"]' <<<"$r" 2>/dev/null) || return 1
  [[ -n $at && $at != None ]] || return 1
  api -X POST -H "Authorization: Bearer $at" "$APP_URL/api-v1/user?id_token=$it" >"$1"
}

user_still_signs_in() {
  local id
  sign_in "$RUN/user.after.json" || return 1
  id=$(user_id "$RUN/user.after.json")
  [[ -n $id && $id == "$(cat "$RUN/user.id")" ]]
}

user_id() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d=d.get("data") or d; print(d.get("id") or "")' "$1" 2>/dev/null; }

wrong_otp_refused() { [[ $(user_token 000000 | field '["error"]' 2>/dev/null) == invalid_grant ]]; }

login_page_has_theme() {
  local page redirect=${PUBLIC_URL//:/%3A}
  page=$(auth "$AUTH_URL/realms/clients/protocol/openid-connect/auth?client_id=osie-ui&response_type=code&scope=openid&redirect_uri=${redirect//\//%2F}")
  [[ $page == *"/login/osie/"* ]]
}

onboarding_done() { [[ $(api -o /dev/null -w '%{http_code}' "$APP_URL/api-v1/admin/onboarding/status") == 404 ]]; }

api_up() {
  local h
  h=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/http:$REL-api-0:8081/proxy/actuator/health" 2>/dev/null) || return 1
  [[ $h == '{"status":"UP"'* || $h == *'"status":"UP"}' ]]
}

bundled_running() {
  local n
  for n in mongodb rabbitmq; do
    [[ -n $(k get pod -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/name=$n" --field-selector=status.phase=Running -o name) ]] || return 1
  done
  [[ $SCENARIO != keycloak ]] || [[ -n $(k get pod -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/name=keycloak" --field-selector=status.phase=Running -o name) ]]
}

new_services_gone() {
  [[ -z $(k get psmdb,rabbitmqcluster -o name 2>/dev/null) ]] || return 1
  [[ -z $(k get keycloak,cluster.postgresql.cnpg.io -o name 2>/dev/null) ]] || return 1
  ! k get configmap "$REL-bundled-migration" >/dev/null 2>&1
}

pv_policies_restored() {
  [[ -z $(kubectl get pv -o jsonpath='{range .items[*]}{.spec.claimRef.namespace}{" "}{.spec.persistentVolumeReclaimPolicy}{"\n"}{end}' | awk -v ns="$NS" '$1 == ns && $2 != "Delete"') ]]
}

mongo_counts() {
  local js
  js=$(sed -n "/^MONGO_COUNT_JS='/,/)))'\$/p" "$MIGRATE" | sed -e "1s/^MONGO_COUNT_JS='//" -e "\$s/'\$//")
  local wl
  wl=$(k get deploy,sts -l "app.kubernetes.io/instance=$REL,app.kubernetes.io/name=mongodb,app.kubernetes.io/component=mongodb" -o name 2>/dev/null | sed -n 1p)
  [[ -n $wl ]] || return 0
  k exec "$wl" -c mongodb -- env DB=osie NOW=$(( $(date +%s) * 1000 )) bash -c 'mongosh --quiet -u root -p "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$1"' _ "$js" 2>/dev/null || true
}

old_volumes_intact() {
  local n
  local old=("$REL-mongodb" "data-$REL-rabbitmq-0")
  [[ ${BUNDLED_HA:-0} != 1 ]] || old=("datadir-$REL-mongodb-0" "datadir-$REL-mongodb-1" "datadir-$REL-mongodb-2" "data-$REL-rabbitmq-0" "data-$REL-rabbitmq-2")
  for n in "${old[@]}"; do
    k get pvc "$n" >/dev/null 2>&1 || return 1
    [[ -z $(k get pvc "$n" -o jsonpath='{.metadata.deletionTimestamp}') ]] || return 1
  done
  [[ $SCENARIO != keycloak ]] || [[ -z $(k get pvc "data-$REL-postgresql-0" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo gone) ]]
}

operators_kept() {
  local crd crds=() images
  [[ $SCENARIO == standalone ]] || crds+=(perconaservermongodbs.psmdb.percona.com rabbitmqclusters.rabbitmq.com)
  [[ $SCENARIO == local || $SCENARIO == existing ]] || crds+=(clusters.postgresql.cnpg.io keycloaks.k8s.keycloak.org)
  for crd in "${crds[@]}"; do kubectl get crd "$crd" >/dev/null 2>&1 || return 1; done
  images=$(kubectl get pods -A --field-selector=status.phase=Running -o jsonpath='{..image}')
  if [[ $SCENARIO == standalone ]]; then
    [[ $images == */cloudnative-pg:* && $images == *keycloak-operator:* ]]
  else
    [[ $images == *percona-server-mongodb-operator:* && $images == */cluster-operator:* ]]
  fi
}

fake_crd() {
  local group=$1 kind=$2 plural=$3 version=$4 schema=$5
  kubectl apply -f - >/dev/null <<EOF
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $plural.$group
spec:
  group: $group
  scope: Namespaced
  names: {kind: $kind, plural: $plural, listKind: ${kind}List}
  versions:
    - name: $version
      served: true
      storage: true
      schema: {openAPIV3Schema: $schema}
EOF
}

existing_crd_rules() {
  check "migrate.sh refuses to start without --values" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN bash $MIGRATE plan --context $CTX --release $REL --namespace $NS >$RUN/no-values.log 2>&1 && grep -q 'Pass --values' $RUN/no-values.log"
  rm -rf "$RUN"/osie-migration-*
  say "operators already in the cluster"
  fake_crd rabbitmq.com RabbitmqCluster rabbitmqclusters v1beta1 \
    '{type: object, properties: {spec: {type: object, properties: {replicas: {type: integer}}}}}'
  check "a CRD that refuses what the script creates stops it before any change" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN bash $MIGRATE plan --context $CTX --release $REL --namespace $NS --values $RUN/customer-values.yaml >$RUN/strict-crd.log 2>&1 && grep -q 'refuses what the script would create' $RUN/strict-crd.log && [[ -z \$(kubectl get ns rabbitmq-system -o name 2>/dev/null) ]]"
  kubectl delete crd rabbitmqclusters.rabbitmq.com --wait >/dev/null
  rm -rf "$RUN"/osie-migration-*
  fake_crd psmdb.percona.com PerconaServerMongoDB perconaservermongodbs v1 '{type: object, x-kubernetes-preserve-unknown-fields: true}'
  check "a CRD with no operator behind it is caught before downtime and rolled back" bash -c \
    "cd $RUN && ! HELM=$HELM_BIN bash $MIGRATE --context $CTX --release $REL --namespace $NS --values $RUN/customer-values.yaml --yes >$RUN/orphan-crd.log 2>&1 && grep -q 'Nothing is handling psmdb' $RUN/orphan-crd.log && ! grep -q 'downtime starts' $RUN/orphan-crd.log"
  check "the failed run left nothing behind" bash -c \
    "[[ -z \$(kubectl -n $NS get psmdb,rabbitmqcluster -o name 2>/dev/null) ]] && ! kubectl -n $NS get configmap $REL-bundled-migration >/dev/null 2>&1"
  check "the bundled services kept running" bundled_running
  kubectl delete crd perconaservermongodbs.psmdb.percona.com --wait >/dev/null
  rm -rf "$RUN"/osie-migration-*
}

values_file_deploys_as_is() {
  local out=$RUN/values-file.dryrun
  "$HELM_BIN" upgrade "$REL" osie --repo https://helm.osie.io --version "$CHART_VERSION" -n "$NS" \
    -f "$RUN/customer-values.yaml" --dry-run=server >"$out" 2>&1 || return 1
  diff <(sed -n '/^MANIFEST:/,/^NOTES:/p' "$out" | sed '1d;$d' | grep -v '^# Source:') \
       <("$HELM_BIN" get manifest "$REL" -n "$NS" | grep -v '^# Source:') >"$RUN/values-file.diff"
}

service_files() {
  local f=()
  [[ $SCENARIO == standalone ]] || f+=("$RUN/mongodb.$REL.yaml" "$RUN/rabbitmq.$REL.yaml")
  [[ $SCENARIO == local || $SCENARIO == existing ]] || f+=("$RUN/keycloak.$REL.yaml")
  printf '%s\n' "${f[@]}"
}

service_files_apply_as_is() {
  local f out
  while read -r f; do
    [[ -f $f ]] || { echo "  missing $f"; return 1; }
    out=$(kubectl apply -n "$NS" --dry-run=server -f "$f" 2>&1) || { echo "$out" | tail -3; return 1; }
  done < <(service_files)
  [[ $SCENARIO == local || $SCENARIO == existing ]] || grep -q osie-keywind "$RUN/keycloak.$REL.yaml"
}

service_files_removed() {
  local f
  while read -r f; do [[ ! -e $f ]] || return 1; done < <(service_files)
}

values_file_restored() { cmp -s "$RUN/customer-values.yaml" "$RUN/values.yaml" && [[ -z $(ls "$RUN"/customer-values.yaml.before-migration-* 2>/dev/null) ]]; }

new_volumes_use_class() {
  local want=$1 got
  got=$(k get pvc -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.storageClassName}{"\n"}{end}' \
    | awk '$1 ~ /^(mongod-data-mongodb-rs0-|persistence-rabbitmq-server-|keycloak-db-)/ {print $2}' | sort -u)
  [[ -n $got && $got == "$want" ]]
}

psmdb_ready() { [[ $(k get psmdb mongodb -o jsonpath='{.status.state}') == ready ]]; }
bundled_gone() { [[ -z $(k get deploy,sts -l "app.kubernetes.io/instance=$REL" -o name | grep -E 'mongodb|rabbitmq|keycloak|postgresql') ]]; }
old_pvcs_kept() { [[ -n $(k get pvc -l "app.kubernetes.io/instance=$REL" -o name) ]]; }

mongo_matches() {
  awk 'NR == FNR { now[$1] = $2; next } $1 !~ /^system/ && (now[$1] + 0) < ($2 + 0) { print "  lost in " $1 ": " $2 " -> " now[$1] + 0; bad = 1 } END { exit bad }' \
    <(mongo_counts) "$1"
}

wait_api() {
  for _ in $(seq 60); do
    api_up && k wait --for=condition=Ready "pod/$REL-api-0" --timeout=5s >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

after_success() {
  [[ $SCENARIO != standalone ]] || { after_success_standalone; return 0; }
  say "after migration"
  forward
  check "osie-api healthy on the new services" wait_api
  check "operator workloads run" psmdb_ready
  check "bundled workloads are gone" bundled_gone
  check "old volumes are kept" old_pvcs_kept
  check "an upgrade with the values file passed to --values changes nothing" values_file_deploys_as_is
  check "the service files apply as they are, the Keycloak theme included" service_files_apply_as_is
  [[ -z $NEW_STORAGE_CLASS ]] || check "the new volumes use storage class $NEW_STORAGE_CLASS" new_volumes_use_class "$NEW_STORAGE_CLASS"
  if [[ ${EXTRA_THEME:-0} == 1 ]]; then
    check "the theme mounted from a ConfigMap is in the new Keycloak" bash -c \
      "kubectl -n $NS exec keycloak-0 -- cat /opt/keycloak/themes/extra/login/theme.properties | grep -q parent=base"
    check "the init container that fills no theme was left out, with a warning" bash -c \
      "! kubectl -n $NS get keycloak keycloak -o json | grep -q unrelated-check && grep -q 'unrelated-check fills no theme' \$(ls -t $RUN/osie-migration-*/migration.log | sed -n 1p)"
    check "keycloak.$REL.yaml carries both themes" bash -c "grep -q extra-theme $RUN/keycloak.$REL.yaml && grep -q osie-keywind $RUN/keycloak.$REL.yaml"
  fi
  if [[ ${BUNDLED_HA:-0} == 1 ]]; then
    check "the three MongoDB members run on three different nodes" bash -c \
      "[[ \$(kubectl -n $NS get pod -l app.kubernetes.io/instance=mongodb,app.kubernetes.io/component=mongod -o jsonpath='{range .items[*]}{.spec.nodeName}{\"\\n\"}{end}' | sort -u | wc -l) == 3 ]]"
    check "RabbitMQ runs 3 nodes, like the bundled one" bash -c \
      "[[ \$(kubectl -n $NS get rabbitmqcluster rabbitmq -o jsonpath='{.spec.replicas}') == 3 && \$(kubectl -n $NS get pod -l app.kubernetes.io/name=rabbitmq,app.kubernetes.io/component=rabbitmq --field-selector=status.phase=Running -o name | wc -l) == 3 ]]"
  fi
  if [[ $SCENARIO == keycloak ]]; then
    check "the Keycloak user signs in with the old password and OTP, and is the same OSIE user" user_still_signs_in
    check "a wrong OTP is refused" wrong_otp_refused
    check "the login page uses the osie theme" login_page_has_theme
  else
    check "onboarding stays done" onboarding_done
  fi
  check "a helm upgrade that brings the bundled services back fails" bash -c \
    "! $HELM_BIN upgrade $REL osie --repo https://helm.osie.io --version $CHART_VERSION -n $NS -f $RUN/values.yaml >$RUN/tripwire.log 2>&1 && grep -q -E 'cannot be imported|PASSWORDS ERROR' $RUN/tripwire.log"
  check "the refused upgrade changed nothing" bash -c "[[ \$($HELM_BIN -n $NS history $REL --max 1 -o json | grep -o '\"status\":\"[a-z]*\"') == '\"status\":\"deployed\"' ]]"
}

after_rollback() {
  [[ $SCENARIO != standalone ]] || { after_rollback_standalone; return 0; }
  say "after rollback"
  forward
  check "osie-api healthy again" wait_api
  check "bundled workloads run again" bundled_running
  check "new services and markers are gone" new_services_gone
  check "operators and their CRDs stay installed" operators_kept
  check "rollback put the values file back" values_file_restored
  check "rollback removed the service files" service_files_removed
  check "volume reclaim policies are back" pv_policies_restored
  check "the old volumes are bound and not being deleted" old_volumes_intact
  local frozen
  frozen=$(ls "$RUN"/osie-migration-*/mongodb-counts.before 2>/dev/null | tail -1 || true)
  if [[ -n $frozen ]]; then
    check "MongoDB holds the documents it had when osie-api stopped" mongo_matches "$frozen"
  fi
  if [[ $SCENARIO == keycloak ]]; then
    check "the Keycloak user still signs in" user_still_signs_in
    check "the login page uses the osie theme" login_page_has_theme
  else
    check "onboarding stays done" onboarding_done
  fi
}

seed_bulk() {
  say "seed: $BIG_DATA_GB GB of documents in the bundled MongoDB"
  local pw start
  pw=$(k get secret "$REL-mongodb" -o jsonpath='{.data.mongodb-root-password}' | base64 -d)
  start=$(date +%s)
  k exec "deploy/$REL-mongodb" -- env PW="$pw" GB="$BIG_DATA_GB" bash -c '
    for w in $(seq 16); do
      mongosh --quiet -u root -p "$PW" --authenticationDatabase admin osie --eval "
        const W = $w, MB = $GB * 1024 / 16;
        const pool = [...Array(256)].map(() => { let s = \"\"; while (s.length < 4096) s += Math.random().toString(36).slice(2); return s.slice(0, 4096); });
        const batches = Math.ceil(MB * 1024 * 1024 / 4200 / 1000);
        for (let b = 0; b < batches; b++) {
          const docs = [];
          for (let i = 0; i < 1000; i++) docs.push({w: W, b, i, p: pool[(b * 7 + i) % 256], t: new Date()});
          db.bulk.insertMany(docs, {ordered: false, writeConcern: {w: 1}});
        }" &
    done
    wait'
  k exec "deploy/$REL-mongodb" -- mongosh --quiet -u root -p "$pw" --authenticationDatabase admin osie \
    --eval 'const s = db.stats(1024 * 1024 * 1024); print("data " + s.dataSize.toFixed(1) + " GB, on disk " + s.storageSize.toFixed(1) + " GB, " + db.bulk.estimatedDocumentCount() + " documents")'
  echo "  seeded in $(( $(date +%s) - start ))s"
}

pause_new_mongodb_at_upgrade() {
  local log
  for _ in $(seq 1800); do
    log=$(ls -t "$RUN"/osie-migration-*/migration.log 2>/dev/null | sed -n 1p || true)
    [[ -n $log ]] && grep -q 'Switching the release to the new services' "$log" && break
    sleep 1
  done
  k patch psmdb mongodb --type=merge -p '{"spec":{"pause":true}}' >/dev/null 2>&1 || true
}

hang_up_during_copy() {
  local log pid
  for _ in $(seq 900); do
    log=$(ls -t "$RUN"/osie-migration-*/migration.log 2>/dev/null | sed -n 1p || true)
    [[ -n $log ]] && grep -q 'Copying MongoDB' "$log" && break
    sleep 1
  done
  pid=$(pgrep -f "migrate.sh --context $CTX " | sed -n 1p || true)
  [[ -n $pid ]] || return 0
  pkill -HUP -P "$pid" || true
  kill -HUP "$pid" || true
}

latest_log_has() { grep -q -- "$1" "$(ls -t "$RUN"/osie-migration-*/migration.log | sed -n 1p)"; }

elsewhere_kubeconfig() {
  local f=$RUN/kubeconfig.elsewhere user
  user=$(kubectl config view -o jsonpath='{.contexts[0].context.user}')
  (umask 077 && cp "$KUBECONFIG" "$f")
  KUBECONFIG=$f kubectl config set-cluster elsewhere --server=https://127.0.0.1:9 >/dev/null
  KUBECONFIG=$f kubectl config set-context elsewhere --cluster=elsewhere --user="$user" >/dev/null
  KUBECONFIG=$f kubectl config use-context elsewhere >/dev/null
}

migrate_again() {
  say "migrate.sh again"
  local rc=0
  FAIL_AFTER= mig "${MIGRATE_ARGS[@]}" || rc=$?
  check "the second migration succeeded" test "$rc" -eq 0
  ((rc == 0)) && after_success
}

main() {
  tools
  if [[ -n $TARGET_CONTEXT ]]; then
    say "cluster $CTX, release $REL in $NS"
    rm -rf "$RUN"/osie-migration-* "$RUN"/osie-plan-*
    if [[ $SCENARIO != existing && ${REUSE:-0} != 1 ]]; then
      if [[ $SCENARIO == standalone ]]; then install_standalone_keycloak; else install_osie; fi
    fi
  elif [[ ${REUSE:-0} == 1 ]] && "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    say "reusing kind cluster $CLUSTER"
  else
    cluster
    if [[ $SCENARIO == standalone ]]; then install_standalone_keycloak; else install_osie; fi
  fi
  if [[ $SCENARIO != standalone ]]; then
    local current
    current=$(release_chart)
    [[ $(printf '%s\n%s\n' "$current" "$CHART_VERSION" | sort -V | sed -n 1p) == "$CHART_VERSION" ]] || upgrade_first
  fi
  forward
  case $SCENARIO in
    keycloak) seed_keycloak ;;
    local) seed_local ;;
    standalone) seed_standalone ;;
  esac
  [[ -z ${BIG_DATA_GB:-} ]] || seed_bulk
  h get values "$REL" -n "$NS" -o yaml >"$RUN/values.yaml"
  cp "$RUN/values.yaml" "$RUN/customer-values.yaml"
  rm -f "$RUN"/customer-values.yaml.before-migration-* "$RUN"/mongodb.*.yaml "$RUN"/rabbitmq.*.yaml "$RUN"/keycloak.*.yaml
  ensure_storage_class
  migrate_args
  [[ -z $NEW_CHART || $SCENARIO == standalone ]] || new_chart_refuses
  [[ -n $TARGET_CONTEXT || $SCENARIO != keycloak || -n $FAIL_AT ]] || existing_crd_rules
  mongo_counts >"$RUN/mongo.before"
  say "migrate.sh${FAIL_AT:+ with FAIL_AFTER=$FAIL_AT}"
  cd "$RUN"
  local rc=0
  elsewhere_kubeconfig
  local saboteur=
  if [[ $FAIL_AT == hangup ]]; then hang_up_during_copy & saboteur=$!; fi
  if [[ $FAIL_AT == upgrade-fails ]]; then pause_new_mongodb_at_upgrade & saboteur=$!; fi
  FAIL_AFTER=$FAIL_AT mig "${MIGRATE_ARGS[@]}" </dev/null || rc=$?
  [[ -z $saboteur ]] || wait "$saboteur" || true
  if [[ -n $FAIL_AT ]]; then
    check "migrate.sh failed as asked" test "$rc" -ne 0
    [[ $FAIL_AT != upgrade-fails ]] || check "it was the helm upgrade that failed" latest_log_has "helm upgrade failed"
    [[ $FAIL_AT != hangup ]] || check "the hangup was rolled back, and the log shows it" latest_log_has "Back to the bundled services"
    after_rollback
  else
    check "migrate.sh succeeded" test "$rc" -eq 0
    if ((rc != 0)); then
      after_rollback
      say "$PASSES passed, $FAILS failed  (migration failed; files $RUN)"
      return 1
    fi
    after_success
    check "rollback refuses a context on another cluster" bash -c \
      "! HELM=$HELM_BIN KUBECONFIG=$RUN/kubeconfig.elsewhere bash $MIGRATE rollback --yes --context elsewhere >$RUN/wrong-cluster.log 2>&1 && grep -q 'not the cluster the migration ran on' $RUN/wrong-cluster.log"
    say "migrate.sh rollback"
    mig rollback --yes || fail "rollback exited non-zero"
    mongo_counts >/dev/null
    after_rollback
    if [[ ${AGAIN:-0} == 1 ]]; then
      migrate_again
      [[ -z $NEW_CHART || $SCENARIO == standalone ]] || new_chart_upgrades
      [[ ${CLEANUP:-0} != 1 ]] || after_cleanup
    fi
  fi
  say "$PASSES passed, $FAILS failed  (cluster $CTX, files $RUN)"
  [[ -n $TARGET_CONTEXT || ${KEEP:-0} == 1 ]] || "$KIND" delete cluster --name "$CLUSTER" >/dev/null 2>&1
  ((FAILS == 0))
}

main
