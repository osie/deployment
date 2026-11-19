#!/usr/bin/env bash
set -Eeuo pipefail

SCENARIO=${1:-keycloak}
FAIL_AT=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
MIGRATE=$HERE/../migrate.sh
CACHE=${CACHE:-$HOME/.cache/osie-migrate-test}
KIND_VERSION=${KIND_VERSION:-v0.31.0}
CHART_VERSION=${CHART_VERSION:-26.8.0}
HELM_BIN=${HELM_BIN:-helm}
CLUSTER=osie-mig-$SCENARIO${FAIL_AT:+-$FAIL_AT}${SUFFIX:+-$SUFFIX}
CLUSTER=${CLUSTER:0:32}
NS=osie
PORT=${PORT:-18080}
RUN=$CACHE/$CLUSTER
OTP_SECRET=12345678901234567890
USER_EMAIL=alice@osie.test
USER_PASSWORD='Alice-Passw0rd!'
PASSES=0
FAILS=0

[[ -n ${OSIE_LICENSE_KEY:-} ]] || { echo "Set OSIE_LICENSE_KEY to a license key for osie-api." >&2; exit 2; }
[[ $SCENARIO == keycloak || $SCENARIO == local ]] || { echo "usage: rehearse.sh keycloak|local [fail-after-step]" >&2; exit 2; }

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
export KUBECONFIG=$RUN/kubeconfig
KIND=$CACHE/kind-$KIND_VERSION
k() { kubectl -n "$NS" "$@"; }
h() { "$HELM_BIN" "$@"; }

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
  "$KIND" create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s
  printf '%s\n' "${IMAGES[@]}" | xargs -P 8 -I{} sh -c 'docker image inspect {} >/dev/null 2>&1 || docker pull -q {} >/dev/null' || true
  printf '%s\n' "${IMAGES[@]}" | xargs -P 4 -I{} sh -c \
    "docker save {} | docker exec -i $CLUSTER-control-plane ctr -n k8s.io images import --platform linux/amd64 - >/dev/null 2>&1 || echo '  could not preload {}'" || true
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
  say "osie $CHART_VERSION with bundled services ($SCENARIO)"
  cat >"$RUN/values.yaml" <<EOF
global:
  ingress:
    enabled: true
    hostname: osie.test
    ingressClassName: traefik
license:
  key: "$OSIE_LICENSE_KEY"
EOF
  [[ $SCENARIO == local ]] && printf 'keycloak:\n  enabled: false\n' >>"$RUN/values.yaml"
  h install osie osie --repo https://helm.osie.io --version "$CHART_VERSION" -n "$NS" --create-namespace \
    -f "$RUN/values.yaml" --wait --timeout 20m >/dev/null
  k get pods
}

forward() {
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

auth() { curl -s -H "Host: auth.osie.test" "$@"; }
api() { curl -s -H "Host: osie.test" "$@"; }
field() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval("d"+sys.argv[1]))' "$1"; }

admin_token() {
  local pw
  pw=$(k get secret osie-keycloak -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d)
  [[ -n $pw ]] || pw=$(cat "$RUN/kc-admin-password")
  printf '%s' "$pw" >"$RUN/kc-admin-password"
  auth -X POST "http://127.0.0.1:$PORT/realms/master/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=admin-cli -d username=osie_admin --data-urlencode "password=$pw" | field '["access_token"]'
}

user_token() {
  local code=${1:-$(totp)}
  auth -X POST "http://127.0.0.1:$PORT/realms/clients/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=osie-ui -d scope=openid -d "username=$USER_EMAIL" \
    --data-urlencode "password=$USER_PASSWORD" -d "totp=$code"
}

seed_keycloak() {
  say "seed: a Keycloak user with a password and OTP, signed in to OSIE once"
  local at body token
  at=$(admin_token)
  body=$(cat <<EOF
{"username":"$USER_EMAIL","email":"$USER_EMAIL","emailVerified":true,"enabled":true,"firstName":"Alice","lastName":"Migrate",
 "credentials":[{"type":"password","value":"$USER_PASSWORD","temporary":false},
  {"type":"otp","userLabel":"phone","secretData":"{\"value\":\"$OTP_SECRET\"}","credentialData":"{\"subType\":\"totp\",\"digits\":6,\"counter\":0,\"period\":30,\"algorithm\":\"HmacSHA1\"}"}]}
EOF
)
  auth -o /dev/null -w '%{http_code}\n' -X POST "http://127.0.0.1:$PORT/admin/realms/clients/users" -H "Authorization: Bearer $at" -H 'Content-Type: application/json' -d "$body"
  sign_in "$RUN/user.before.json" || { echo "no user token" >&2; return 1; }
  user_id "$RUN/user.before.json" >"$RUN/user.id"
  [[ -s $RUN/user.id ]] || { cat "$RUN/user.before.json" >&2; return 1; }
  echo "  OSIE user id $(cat "$RUN/user.id")"
}

seed_local() {
  say "seed: onboard a local admin in osie-api"
  api -X POST -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/api-v1/admin/onboarding/initialize-user" \
    -d "{\"email\":\"admin@osie.test\",\"firstname\":\"Ada\",\"lastname\":\"Admin\",\"password\":\"$USER_PASSWORD\",\"passwordConfirmation\":\"$USER_PASSWORD\"}" -o /dev/null -w '  initialize-user %{http_code}\n'
  api -X POST -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/api-v1/admin/onboarding/platform-configuration" -d '{"name":"Rehearsal"}' -o /dev/null -w '  platform %{http_code}\n'
  api -X POST -H 'Content-Type: application/json' "http://127.0.0.1:$PORT/api-v1/admin/onboarding/billing-configuration" \
    -d '{"companyName":"Rehearsal SRL","country":"RO","city":"Iasi","address":"Str. 1","currency":"EUR"}' -o /dev/null -w '  billing %{http_code}\n'
}

sign_in() {
  local r at it
  sleep $(( 31 - $(date +%s) % 30 ))
  r=$(user_token)
  at=$(field '["access_token"]' <<<"$r" 2>/dev/null) || return 1
  it=$(field '["id_token"]' <<<"$r" 2>/dev/null) || return 1
  [[ -n $at && $at != None ]] || return 1
  api -X POST -H "Authorization: Bearer $at" "http://127.0.0.1:$PORT/api-v1/user?id_token=$it" >"$1"
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
  local page
  page=$(auth "http://127.0.0.1:$PORT/realms/clients/protocol/openid-connect/auth?client_id=osie-ui&response_type=code&scope=openid&redirect_uri=http%3A%2F%2Fosie.test%2F")
  [[ $page == *"/login/osie/"* ]]
}

onboarding_done() { [[ $(api -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/api-v1/admin/onboarding/status") == 404 ]]; }

api_up() {
  local h
  h=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/http:osie-api-0:8081/proxy/actuator/health" 2>/dev/null) || return 1
  [[ $h == '{"status":"UP"'* ]]
}

bundled_running() {
  local n
  for n in mongodb rabbitmq; do
    [[ -n $(k get pod -l "app.kubernetes.io/instance=osie,app.kubernetes.io/name=$n" --field-selector=status.phase=Running -o name) ]] || return 1
  done
  [[ $SCENARIO == local ]] || [[ -n $(k get pod -l "app.kubernetes.io/instance=osie,app.kubernetes.io/name=keycloak" --field-selector=status.phase=Running -o name) ]]
}

new_services_gone() {
  [[ -z $(k get psmdb,rabbitmqcluster -o name 2>/dev/null) ]] || return 1
  [[ -z $(k get keycloak,cluster.postgresql.cnpg.io -o name 2>/dev/null) ]] || return 1
  ! k get configmap osie-bundled-migration >/dev/null 2>&1
}

pv_policies_restored() { [[ -z $(kubectl get pv -o jsonpath='{range .items[*]}{.spec.persistentVolumeReclaimPolicy}{"\n"}{end}' | grep -v Delete) ]]; }

mongo_counts() {
  local js
  js=$(sed -n "/^MONGO_COUNT_JS='/,/)))'\$/p" "$MIGRATE" | sed -e "1s/^MONGO_COUNT_JS='//" -e "\$s/'\$//")
  k exec deploy/osie-mongodb -c mongodb -- env DB=osie NOW=$(( $(date +%s) * 1000 )) bash -c 'mongosh --quiet -u root -p "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin --eval "$1"' _ "$js" 2>/dev/null || true
}

old_volumes_intact() {
  local n
  for n in osie-mongodb data-osie-rabbitmq-0; do
    k get pvc "$n" >/dev/null 2>&1 || return 1
    [[ -z $(k get pvc "$n" -o jsonpath='{.metadata.deletionTimestamp}') ]] || return 1
  done
  [[ $SCENARIO == local ]] || [[ -z $(k get pvc data-osie-postgresql-0 -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || echo gone) ]]
}

mongo_matches() {
  awk 'NR == FNR { now[$1] = $2; next } $1 !~ /^system/ && (now[$1] + 0) < ($2 + 0) { print "  lost in " $1 ": " $2 " -> " now[$1] + 0; bad = 1 } END { exit bad }' \
    <(mongo_counts) "$1"
}

wait_api() {
  for _ in $(seq 60); do
    api_up && k wait --for=condition=Ready pod/osie-api-0 --timeout=5s >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

after_success() {
  say "after migration"
  forward
  check "osie-api healthy on the new services" wait_api
  check "operator workloads run" bash -c '[[ -n $(kubectl -n osie get psmdb mongodb -o jsonpath={.status.state} | grep ready) ]]'
  check "bundled workloads are gone" bash -c '[[ -z $(kubectl -n osie get deploy,sts -l app.kubernetes.io/instance=osie -o name | grep -E "mongodb|rabbitmq|keycloak|postgresql") ]]'
  check "old volumes are kept" bash -c '[[ -n $(kubectl -n osie get pvc -l app.kubernetes.io/instance=osie -o name) ]]'
  if [[ $SCENARIO == keycloak ]]; then
    check "the Keycloak user signs in with the old password and OTP, and is the same OSIE user" user_still_signs_in
    check "a wrong OTP is refused" wrong_otp_refused
    check "the login page uses the osie theme" login_page_has_theme
  else
    check "onboarding stays done" onboarding_done
  fi
  check "a helm upgrade that brings the bundled services back fails" bash -c \
    "! $HELM_BIN upgrade osie osie --repo https://helm.osie.io --version $CHART_VERSION -n osie -f $RUN/values.yaml >$RUN/tripwire.log 2>&1 && grep -q -E 'cannot be imported|PASSWORDS ERROR' $RUN/tripwire.log"
  check "the refused upgrade changed nothing" bash -c "[[ \$($HELM_BIN -n osie history osie --max 1 -o json | grep -o '\"status\":\"[a-z]*\"') == '\"status\":\"deployed\"' ]]"
}

after_rollback() {
  say "after rollback"
  forward
  check "osie-api healthy again" wait_api
  check "bundled workloads run again" bundled_running
  check "new services and markers are gone" new_services_gone
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

elsewhere_kubeconfig() {
  local f=$RUN/kubeconfig.elsewhere
  cp "$KUBECONFIG" "$f"
  KUBECONFIG=$f kubectl config set-cluster elsewhere --server=https://127.0.0.1:9 >/dev/null
  KUBECONFIG=$f kubectl config set-context elsewhere --cluster=elsewhere --user="kind-$CLUSTER" >/dev/null
  KUBECONFIG=$f kubectl config use-context elsewhere >/dev/null
}

main() {
  tools
  if [[ ${REUSE:-0} == 1 ]] && "$KIND" get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
    say "reusing kind cluster $CLUSTER"
  else
    cluster
    install_osie
  fi
  forward
  if [[ $SCENARIO == keycloak ]]; then seed_keycloak; else seed_local; fi
  mongo_counts >"$RUN/mongo.before"
  say "migrate.sh${FAIL_AT:+ with FAIL_AFTER=$FAIL_AT}"
  cd "$RUN"
  local rc=0
  elsewhere_kubeconfig
  FAIL_AFTER=$FAIL_AT HELM="$HELM_BIN" KUBECONFIG=$RUN/kubeconfig.elsewhere bash "$MIGRATE" --context "kind-$CLUSTER" --yes || rc=$?
  if [[ -n $FAIL_AT ]]; then
    check "migrate.sh failed as asked" test "$rc" -ne 0
    after_rollback
  else
    check "migrate.sh succeeded" test "$rc" -eq 0
    if ((rc != 0)); then
      after_rollback
      say "$PASSES passed, $FAILS failed  (migration failed; cluster $CLUSTER kept, files $RUN)"
      return 1
    fi
    after_success
    check "rollback refuses a context on another cluster" bash -c \
      "! HELM=$HELM_BIN KUBECONFIG=$RUN/kubeconfig.elsewhere bash $MIGRATE rollback --yes --context elsewhere >$RUN/wrong-cluster.log 2>&1 && grep -q 'not the cluster the migration ran on' $RUN/wrong-cluster.log"
    say "migrate.sh rollback"
    HELM="$HELM_BIN" KUBECONFIG=$RUN/kubeconfig.elsewhere bash "$MIGRATE" rollback --yes || fail "rollback exited non-zero"
    mongo_counts >/dev/null
    after_rollback
  fi
  say "$PASSES passed, $FAILS failed  (cluster $CLUSTER, files $RUN)"
  [[ ${KEEP:-0} == 1 ]] || "$KIND" delete cluster --name "$CLUSTER" >/dev/null 2>&1
  ((FAILS == 0))
}

main
