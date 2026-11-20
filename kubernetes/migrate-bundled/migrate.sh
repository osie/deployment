#!/usr/bin/env bash
set -Eeuo pipefail
((BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] >= 404)) \
  || { echo "migrate.sh needs bash 4.4 or later; this is $BASH_VERSION. On macOS: brew install bash, then run it with that bash." >&2; exit 1; }

PSMDB_OPERATOR_VERSION=1.22.0
PSMDB_IMAGE=percona/percona-server-mongodb:7.0.18-11
RABBITMQ_OPERATOR_VERSION=v2.21.0
CNPG_VERSION=1.30.2
CNPG_POSTGRES_IMAGE=ghcr.io/cloudnative-pg/postgresql:17
KEYCLOAK_OPERATOR_VERSION=26.8.2
MIN_CHART_VERSION=26.8.0

RELEASE=${RELEASE:-}
NAMESPACE=${NAMESPACE:-}
KUBE_CONTEXT=${KUBE_CONTEXT:-}
ASSUME_YES=${ASSUME_YES:-0}
INSTALL_OPERATORS=${INSTALL_OPERATORS:-1}
OSIE_CHART=${OSIE_CHART:-}
OSIE_CHART_REPO=${OSIE_CHART_REPO:-https://helm.osie.io}
KEYCLOAK_IMAGE=${KEYCLOAK_IMAGE:-}
MONGODB_NAME=${MONGODB_NAME:-mongodb}
MONGODB_HA=${MONGODB_HA:-0}
MONGODB_MEMORY=${MONGODB_MEMORY:-2Gi}
RABBITMQ_NAME=${RABBITMQ_NAME:-rabbitmq}
KEYCLOAK_NAME=${KEYCLOAK_NAME:-keycloak}
KEYCLOAK_DB_NAME=${KEYCLOAK_DB_NAME:-keycloak-db}
ALLOW_RABBITMQ_CLIENTS=${ALLOW_RABBITMQ_CLIENTS:-0}
TIMEOUT=${TIMEOUT:-20m}
WORKDIR=${WORKDIR:-}
FAIL_AFTER=${FAIL_AFTER:-}

MARK=osie.io/migrated-from
COMMAND=migrate
CURRENT_STEP=start
MUTATED=0
COMMITTED=0
KC=()
HM=()
CLUSTER_DESC=
CLUSTER_ID=
NEED_OPERATORS=()
REUSED_OPERATORS=()
OPERATOR_LINES=()
HM_APPLY=()

if [[ -t 1 ]]; then
  BOLD=$'\e[1m' RED=$'\e[31m' GREEN=$'\e[32m' YELLOW=$'\e[33m' DIM=$'\e[2m' RESET=$'\e[0m'
else
  BOLD='' RED='' GREEN='' YELLOW='' DIM='' RESET=''
fi

say()  { printf '%s\n' "$*"; }
step() { CURRENT_STEP=$1; shift; printf '\n%s▸ %s%s\n' "$BOLD" "$*" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  %s! %s%s\n' "$YELLOW" "$*" "$RESET"; }
die()  { printf '\n%s✗ %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

usage() {
  cat <<EOF
Moves an OSIE helm release off the bundled Bitnami MongoDB, RabbitMQ and Keycloak
onto operator-managed services, keeping every user, every theme and all data.
If any step fails, it puts everything back by itself.

  bash migrate.sh             show the plan, ask, then migrate
  bash migrate.sh plan        show the plan only, change nothing
  bash migrate.sh rollback    go back to the bundled services (works until cleanup)
  bash migrate.sh cleanup     delete the old volumes, once you are happy

Options:
  --release <name>     the OSIE helm release (found by itself when there is only one)
  --namespace <ns>     its namespace
  --context <name>     the kubeconfig context to use (the current one by default)
  --yes                do not ask before starting
  --workdir <dir>      for rollback and cleanup: the folder a migration wrote

kubectl and helm are found on PATH or through microk8s, k3s, k0s and rke2.
Set KUBECTL="..." or HELM="..." to use something else, for example
  KUBECTL="microk8s kubectl" HELM="microk8s helm3" bash migrate.sh

All settings are listed in README.md next to this script.
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      plan|migrate|rollback|cleanup) COMMAND=$1 ;;
      --release) RELEASE=${2:?--release needs a value}; shift ;;
      --release=*) RELEASE=${1#*=} ;;
      --namespace|-n) NAMESPACE=${2:?--namespace needs a value}; shift ;;
      --namespace=*) NAMESPACE=${1#*=} ;;
      --context|--kube-context) KUBE_CONTEXT=${2:?--context needs a value}; shift ;;
      --context=*|--kube-context=*) KUBE_CONTEXT=${1#*=} ;;
      --workdir) WORKDIR=${2:?--workdir needs a value}; shift ;;
      --workdir=*) WORKDIR=${1#*=} ;;
      --yes|-y) ASSUME_YES=1 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Unknown argument: $1" ;;
    esac
    shift
  done
}

kc() { "${KC[@]}" ${KUBE_CONTEXT:+--context "$KUBE_CONTEXT"} "$@"; }
k()  { kc -n "$NAMESPACE" "$@"; }
hm() { "${HM[@]}" ${KUBE_CONTEXT:+--kube-context "$KUBE_CONTEXT"} "$@"; }

checkpoint() { [[ $FAIL_AFTER == "$1" ]] && die "Stopping after '$1' because FAIL_AFTER=$1." || true; }

json_str() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }

to_seconds() {
  local v=$1
  case $v in
    *h) echo $(( ${v%h} * 3600 )) ;;
    *m) echo $(( ${v%m} * 60 )) ;;
    *s) echo "${v%s}" ;;
    *) echo "$v" ;;
  esac
}

to_mi() {
  local q=$1 n
  case $q in
    *Ti) n=${q%Ti}; echo $(( n * 1024 * 1024 )) ;;
    *Gi) n=${q%Gi}; echo $(( n * 1024 )) ;;
    *Mi) n=${q%Mi}; echo "$n" ;;
    *Ki) n=${q%Ki}; echo $(( (n + 1023) / 1024 )) ;;
    *T) n=${q%T}; echo $(( n * 1000000000000 / 1048576 )) ;;
    *G) n=${q%G}; echo $(( n * 1000000000 / 1048576 + 1 )) ;;
    *M) n=${q%M}; echo $(( n * 1000000 / 1048576 + 1 )) ;;
    *) echo $(( ${q:-0} / 1048576 + 1 )) ;;
  esac
}

size_at_least() {
  local mi min_mi
  mi=$(to_mi "${1:-0}")
  min_mi=$(to_mi "$2")
  (( mi < min_mi )) && mi=$min_mi
  echo "$(( (mi + 1023) / 1024 ))Gi"
}

try_cmd() {
  local -n out=$1
  local probe=$2 c
  shift 2
  for c in "$@"; do
    read -ra cand <<<"$c"
    if command -v "${cand[0]}" >/dev/null 2>&1 && "${cand[@]}" $probe >/dev/null 2>&1; then
      out=("${cand[@]}")
      return 0
    fi
  done
  return 1
}

cluster_reachable() { kc get --raw /version >/dev/null 2>&1 && hm list -A >/dev/null 2>&1; }
cluster_id() { kc get namespace kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null || true; }
# Helm 4 applies server-side and refuses fields changed with kubectl; client-side keeps them, as Helm 3 does
helm_apply_flags() { [[ $(hm version --short 2>/dev/null) == v3* ]] && HM_APPLY=() || HM_APPLY=(--server-side=false); }

detect_tools() {
  step tools "Finding kubectl and helm"
  if [[ -n ${KUBECTL:-} ]]; then
    read -ra KC <<<"$KUBECTL"
    kc version --client >/dev/null 2>&1 || die "KUBECTL=\"$KUBECTL\" does not run."
  else
    try_cmd KC "version --client" kubectl "microk8s kubectl" "k3s kubectl" "k0s kubectl" /var/lib/rancher/rke2/bin/kubectl \
      || die "No kubectl found. Install it, or set KUBECTL, for example KUBECTL=\"microk8s kubectl\"."
  fi
  if [[ -n ${HELM:-} ]]; then
    read -ra HM <<<"$HELM"
    hm version --short >/dev/null 2>&1 || die "HELM=\"$HELM\" does not run."
  else
    try_cmd HM "version --short" helm "microk8s helm3" "microk8s helm" \
      || die "No helm found. Install helm 3 or 4, or set HELM, for example HELM=\"microk8s helm3\"."
  fi
  if [[ -n $KUBE_CONTEXT ]]; then
    kc config get-contexts "$KUBE_CONTEXT" >/dev/null 2>&1 \
      || die "Your kubeconfig has no context \"$KUBE_CONTEXT\". 'kubectl config get-contexts' lists them."
  elif ! cluster_reachable && [[ -z ${KUBECONFIG:-} ]]; then
    local f
    for f in /etc/rancher/k3s/k3s.yaml /etc/rancher/rke2/rke2.yaml /var/snap/microk8s/current/credentials/client.config; do
      if [[ -r $f ]]; then
        export KUBECONFIG=$f
        cluster_reachable && break
        unset KUBECONFIG
      fi
    done
  fi
  kc get --raw /version >/dev/null 2>&1 || die "\"${KC[*]}\" cannot reach the cluster${KUBE_CONTEXT:+ of context $KUBE_CONTEXT}. Set KUBECONFIG, --context, or KUBECTL to a command that can."
  hm list -A >/dev/null 2>&1 || die "\"${HM[*]}\" cannot reach the cluster${KUBE_CONTEXT:+ of context $KUBE_CONTEXT}. Set KUBECONFIG, --context, or HELM to a command that can."
  CLUSTER_DESC=$(kc config view --minify -o jsonpath='{.contexts[0].name} at {.clusters[0].cluster.server}' 2>/dev/null || true)
  CLUSTER_ID=$(cluster_id)
  helm_apply_flags
  ok "kubectl: ${KC[*]}"
  ok "helm: ${HM[*]} ($(hm version --short 2>/dev/null))"
  [[ -n ${KUBECONFIG:-} ]] && ok "kubeconfig: $KUBECONFIG"
  [[ -n $CLUSTER_DESC ]] && ok "cluster: $CLUSTER_DESC"
  return 0
}

json_field() { sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}[,}].*/\1/p" <<<"$1" | sed -n 1p; }

version_ge() { [[ $(printf '%s\n%s\n' "$1" "$2" | sort -V | sed -n 1p) == "$2" ]]; }

has_line() { local text=$1; shift; awk -v a="$1" -v b="${2:-}" '$0 ~ a && (b == "" || $0 ~ b) { f = 1 } END { exit !f }' <<<"$text"; }

find_release() {
  step release "Finding the OSIE release"
  local all o n ns ch st rv rows=()
  all=$(hm list -A --deployed --failed --pending -o json) || die "helm list failed."
  while read -r o; do
    [[ -z $o ]] && continue
    n=$(json_field "$o" name); ns=$(json_field "$o" namespace); ch=$(json_field "$o" chart)
    st=$(json_field "$o" status); rv=$(json_field "$o" revision)
    [[ $ch =~ ^osie-[0-9] ]] || continue
    [[ -n $RELEASE && $n != "$RELEASE" ]] && continue
    [[ -n $NAMESPACE && $ns != "$NAMESPACE" ]] && continue
    rows+=("$n"$'\t'"$ns"$'\t'"$ch"$'\t'"$st"$'\t'"$rv")
  done < <(grep -o '{[^{}]*}' <<<"$all" || true)
  ((${#rows[@]})) || die "No OSIE helm release found${RELEASE:+ named $RELEASE}${NAMESPACE:+ in namespace $NAMESPACE}."
  if ((${#rows[@]} > 1)); then
    say "  Several OSIE releases:"
    printf '    %s\n' "${rows[@]//$'\t'/  }"
    die "Pick one with --release <name> --namespace <ns>."
  fi
  IFS=$'\t' read -r RELEASE NAMESPACE CHART_NAME RELEASE_STATUS REVISION <<<"${rows[0]}"
  CHART_VERSION=${CHART_NAME#osie-}
  version_ge "$CHART_VERSION" "$MIN_CHART_VERSION" \
    || die "Release $RELEASE runs chart $CHART_VERSION. Upgrade OSIE to chart $MIN_CHART_VERSION or later the way you usually do, then run this again. README.md shows a command for it."
  [[ $RELEASE_STATUS == deployed ]] || die "Release $RELEASE is '$RELEASE_STATUS'. Bring it back to 'deployed' first (helm rollback or a fixed upgrade)."
  k get secret "sh.helm.release.v1.$RELEASE.v$REVISION" >/dev/null 2>&1 \
    || k get configmap "sh.helm.release.v1.$RELEASE.v$REVISION" >/dev/null 2>&1 \
    || die "kubectl does not see the release helm sees. They point at different clusters; set KUBECONFIG for both."
  ok "$RELEASE in namespace $NAMESPACE, chart $CHART_VERSION, revision $REVISION"
}

workload() {
  k get deploy,sts -l "app.kubernetes.io/instance=$RELEASE,$1" -o name 2>/dev/null | sed -n 1p
}

selector_of() {
  k get "$1" -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' | sed 's/,$//'
}

first_pod() { { k get pod -l "$1" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true; } | sed -n 1p; }

container_env() {
  k get "$1" -o go-template="{{range .spec.template.spec.containers}}{{if eq .name \"$2\"}}{{range .env}}{{if eq .name \"$3\"}}{{with .value}}{{.}}{{end}}{{end}}{{end}}{{end}}{{end}}"
}

container_env_secret() {
  k get "$1" -o go-template="{{range .spec.template.spec.containers}}{{if eq .name \"$2\"}}{{range .env}}{{if eq .name \"$3\"}}{{with .valueFrom}}{{with .secretKeyRef}}{{.name}}/{{.key}}{{end}}{{end}}{{end}}{{end}}{{end}}{{end}}"
}

secret_value() {
  local v
  v=$(k get secret "$1" -o go-template="{{with index .data \"$2\"}}{{.}}{{end}}" 2>/dev/null) || return 1
  [[ -n $v ]] || return 1
  base64 -d <<<"$v"
}

cm_value() { k get configmap "$1" -o go-template="{{with index .data \"$2\"}}{{.}}{{end}}" 2>/dev/null || true; }
current_revision() { hm history "$RELEASE" -n "$NAMESPACE" --max 1 -o json 2>/dev/null | grep -o '"revision":[0-9]*' | sed -n '1s/.*://p'; }

pvc_of() {
  k get pvc -l "app.kubernetes.io/instance=$RELEASE,$1" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
}

issuers_from() {
  awk '
    /^auth:/ { a = 1; next }
    a && /^[^ ]/ { a = 0 }
    a && /^  [a-z-]+:/ { s = $1; sub(":", "", s) }
    a && /^      issuer-uri: / { print s "\t" $2 }
  '
}

issuer_of() { awk -F'\t' -v s="$2" '$1 == s { print $2 }' <<<"$1"; }

discover() {
  step discover "Looking at what the release runs"
  local comp
  MONGO_WL=$(workload "app.kubernetes.io/name=mongodb,app.kubernetes.io/component=mongodb")
  RABBIT_WL=$(workload "app.kubernetes.io/name=rabbitmq")
  KC_WL=$(workload "app.kubernetes.io/name=keycloak,app.kubernetes.io/component=keycloak")
  PG_WL=$(workload "app.kubernetes.io/name=postgresql")
  API_NAME= UI_NAME= ADMIN_NAME=
  while read -r n comp; do
    case $comp in
      *-api) [[ $n == statefulset.apps/* ]] && API_NAME=${n#*/} ;;
      *-ui) [[ $n == deployment.apps/* ]] && UI_NAME=${n#*/} ;;
      *-admin) [[ $n == deployment.apps/* ]] && ADMIN_NAME=${n#*/} ;;
    esac
  done < <(k get deploy,sts -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{" "}{.metadata.labels.app\.kubernetes\.io/component}{"\n"}{end}' \
             | sed -e 's#^StatefulSet/#statefulset.apps/#' -e 's#^Deployment/#deployment.apps/#')
  [[ -n $API_NAME ]] || die "Could not find the osie-api StatefulSet of release $RELEASE."

  if [[ -z $MONGO_WL && -z $RABBIT_WL && -z $KC_WL ]]; then
    ok "Release $RELEASE runs no bundled MongoDB, RabbitMQ or Keycloak. Nothing to migrate."
    exit 0
  fi

  API_SEL=$(selector_of "statefulset/$API_NAME")
  API_REPLICAS=$(k get sts "$API_NAME" -o jsonpath='{.spec.replicas}')
  [[ $API_REPLICAS =~ ^[1-9] ]] || API_REPLICAS=1
  if has_line "$(k get hpa -o jsonpath='{range .items[*]}{.spec.scaleTargetRef.name}{"\n"}{end}' 2>/dev/null || true)" "^$API_NAME\$"; then
    die "osie-api has a HorizontalPodAutoscaler, which would restart it during the copy. Set api.autoscaling.enabled=false, upgrade, then run this again."
  fi

  API_CONFIG=$(cm_value "$API_NAME-config" application.yml)
  [[ -n $API_CONFIG ]] || die "ConfigMap $API_NAME-config has no application.yml."
  ISSUERS=$(issuers_from <<<"$API_CONFIG")

  if [[ -n $MONGO_WL ]]; then discover_mongodb; fi
  if [[ -n $RABBIT_WL ]]; then discover_rabbitmq; fi
  if [[ -n $KC_WL ]]; then discover_keycloak; fi
}

discover_mongodb() {
  MONGO_SEL=$(selector_of "$MONGO_WL")
  MONGO_POD=$(first_pod "$MONGO_SEL")
  [[ -n $MONGO_POD ]] || die "The bundled MongoDB ($MONGO_WL) has no running pod. Start it first; the data is copied from it."
  MONGO_DB=$(container_env "statefulset/$API_NAME" "$(k get sts "$API_NAME" -o jsonpath='{.spec.template.spec.containers[0].name}')" MONGODB_DATABASE)
  MONGO_DB=${MONGO_DB:-osie}
  mapfile -t MONGO_PVCS < <(pvc_of "app.kubernetes.io/name=mongodb")
  MONGO_SC= MONGO_SIZE=
  if ((${#MONGO_PVCS[@]})); then
    MONGO_SC=$(k get pvc "${MONGO_PVCS[0]}" -o jsonpath='{.spec.storageClassName}')
    MONGO_SIZE=$(k get pvc "${MONGO_PVCS[0]}" -o jsonpath='{.spec.resources.requests.storage}')
  fi
  MONGO_TARGET_SIZE=$(size_at_least "$MONGO_SIZE" 10Gi)
  MONGO_STANDALONE_PVC=
  [[ $MONGO_WL == deployment.apps/* && ${#MONGO_PVCS[@]} -gt 0 ]] && MONGO_STANDALONE_PVC=${MONGO_PVCS[0]}
  MONGO_DATA=$(k exec "$MONGO_POD" -c mongodb -- bash -c "$MONGO_SOURCE_AUTH"'
    mongosh --quiet "${src[@]}" --eval "print(Math.round(db.getSiblingDB(\"$1\").stats().dataSize))"' _ "$MONGO_DB" 2>/dev/null | tail -1) || MONGO_DATA=
  [[ $MONGO_DATA =~ ^[0-9]+$ ]] || MONGO_DATA=
  if k get psmdb "$MONGODB_NAME" >/dev/null 2>&1; then
    die "A Percona MongoDB named '$MONGODB_NAME' already exists in $NAMESPACE. Set MONGODB_NAME to another name."
  fi
  ok "MongoDB: ${MONGO_WL#*/} (${MONGO_WL%%.*}), database '$MONGO_DB'${MONGO_DATA:+, $(( MONGO_DATA / 1048576 )) MiB of data}"
}

discover_rabbitmq() {
  RABBIT_SEL=$(selector_of "$RABBIT_WL")
  RABBIT_POD=$(first_pod "$RABBIT_SEL")
  RABBIT_SVC=${RABBIT_WL#*/}
  RABBIT_REPLICAS=$(k get "$RABBIT_WL" -o jsonpath='{.spec.replicas}')
  mapfile -t RABBIT_PVCS < <(pvc_of "app.kubernetes.io/name=rabbitmq")
  RABBIT_SC= RABBIT_SIZE=
  if ((${#RABBIT_PVCS[@]})); then
    RABBIT_SC=$(k get pvc "${RABBIT_PVCS[0]}" -o jsonpath='{.spec.storageClassName}')
    RABBIT_SIZE=$(k get pvc "${RABBIT_PVCS[0]}" -o jsonpath='{.spec.resources.requests.storage}')
  fi
  RABBIT_TARGET_SIZE=$(size_at_least "$RABBIT_SIZE" 5Gi)
  if k get rabbitmqcluster "$RABBITMQ_NAME" >/dev/null 2>&1; then
    die "A RabbitmqCluster named '$RABBITMQ_NAME' already exists in $NAMESPACE. Set RABBITMQ_NAME to another name."
  fi
  local type clients
  type=$(k get svc "$RABBIT_SVC" -o jsonpath='{.spec.type}' 2>/dev/null || echo ClusterIP)
  clients=$( { kc get configmaps,deployments,statefulsets,daemonsets -A -l "app.kubernetes.io/instance!=$RELEASE" \
      -o jsonpath='{range .items[*]}{.kind}{" "}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.data}{.spec.template.spec.containers[*].env}{"\n"}{end}' 2>/dev/null || true; } \
      | grep -F "$RABBIT_SVC" | cut -f1 || true)
  if [[ $type != ClusterIP || -n $clients ]] && [[ $ALLOW_RABBITMQ_CLIENTS != 1 ]]; then
    [[ $type != ClusterIP ]] && warn "Service $RABBIT_SVC is a $type, so something outside the cluster may publish to it."
    [[ -n $clients ]] && { warn "These also point at $RABBIT_SVC:"; while read -r c; do note "    $c"; done <<<"$clients"; }
    die "They would lose RabbitMQ when it moves. Re-point them at '$RABBITMQ_NAME.$NAMESPACE.svc:5672' afterwards, then run again with ALLOW_RABBITMQ_CLIENTS=1."
  fi
  ok "RabbitMQ: $RABBIT_SVC (${RABBIT_REPLICAS:-1} node$([[ ${RABBIT_REPLICAS:-1} == 1 ]] || echo s)); queues are refilled by osie-api from MongoDB"
}

discover_keycloak() {
  KC_STS=${KC_WL#*/}
  KC_SEL=$(selector_of "$KC_WL")
  KC_REPLICAS=$(k get "$KC_WL" -o jsonpath='{.spec.replicas}')
  [[ $KC_REPLICAS =~ ^[1-9] ]] || KC_REPLICAS=1
  KC_ENV_CM=$(k get "$KC_WL" -o go-template='{{range .spec.template.spec.containers}}{{if eq .name "keycloak"}}{{range .envFrom}}{{with .configMapRef}}{{.name}} {{end}}{{end}}{{end}}{{end}}' | awk '{print $1}')
  kc_env() {
    local v
    v=$(container_env "$KC_WL" keycloak "$1")
    [[ -z $v && -n $KC_ENV_CM ]] && v=$(cm_value "$KC_ENV_CM" "$1")
    printf '%s' "$v"
  }
  KC_IMAGE_OLD=$(k get "$KC_WL" -o go-template='{{range .spec.template.spec.containers}}{{if eq .name "keycloak"}}{{.image}}{{end}}{{end}}')
  if [[ ! $KC_IMAGE_OLD =~ (^|/)bitnami(legacy)?/keycloak: && -z $KEYCLOAK_IMAGE ]]; then
    die "Keycloak runs your own image ($KC_IMAGE_OLD), which may carry themes or providers. Build one FROM quay.io/keycloak/keycloak:$KEYCLOAK_OPERATOR_VERSION with them under /opt/keycloak/, then set KEYCLOAK_IMAGE to it."
  fi
  KC_DB_HOST=$(kc_env KEYCLOAK_DATABASE_HOST)
  KC_DB_PORT=$(kc_env KEYCLOAK_DATABASE_PORT); KC_DB_PORT=${KC_DB_PORT:-5432}
  KC_DB_NAME=$(kc_env KEYCLOAK_DATABASE_NAME)
  KC_DB_USER=$(kc_env KEYCLOAK_DATABASE_USER)
  local ref
  ref=$(container_env_secret "$KC_WL" keycloak KEYCLOAK_DATABASE_PASSWORD)
  [[ -n $PG_WL && -n $KC_DB_HOST && $KC_DB_HOST == "${PG_WL#*/}"* ]] \
    || die "Keycloak uses a database outside this release ($KC_DB_HOST). This script moves only the bundled PostgreSQL; contact OSIE support."
  [[ -n $ref ]] || die "Could not find the Keycloak database password in $KC_WL."
  KC_DB_PASSWORD=$(secret_value "${ref%%/*}" "${ref#*/}") || die "Could not read the Keycloak database password from secret ${ref%%/*}."
  PG_SEL=$(selector_of "$PG_WL")
  PG_POD=$(first_pod "$PG_SEL")
  [[ -n $PG_POD ]] || die "The bundled PostgreSQL ($PG_WL) has no running pod. Start it first; Keycloak's data is copied from it."
  mapfile -t PG_PVCS < <(pvc_of "app.kubernetes.io/name=postgresql")
  PG_SC= PG_SIZE=
  if ((${#PG_PVCS[@]})); then
    PG_SC=$(k get pvc "${PG_PVCS[0]}" -o jsonpath='{.spec.storageClassName}')
    PG_SIZE=$(k get pvc "${PG_PVCS[0]}" -o jsonpath='{.spec.resources.requests.storage}')
  fi
  PG_TARGET_SIZE=$(size_at_least "$PG_SIZE" 5Gi)
  KC_ADMIN_USER=$(kc_env KEYCLOAK_ADMIN)
  ref=$(container_env_secret "$KC_WL" keycloak KEYCLOAK_ADMIN_PASSWORD)
  KC_ADMIN_PASSWORD=
  [[ -n $ref ]] && KC_ADMIN_PASSWORD=$(secret_value "${ref%%/*}" "${ref#*/}" || true)

  local extra a i
  extra=$(kc_env KEYCLOAK_EXTRA_ARGS)
  KC_FEATURES=() KC_IGNORED_ARGS=()
  read -ra a <<<"$extra"
  for ((i = 0; i < ${#a[@]}; i++)); do
    case ${a[i]} in
      --features=*) IFS=, read -ra f <<<"${a[i]#--features=}"; KC_FEATURES+=("${f[@]}") ;;
      --features) ((i++)); IFS=, read -ra f <<<"${a[i]:-}"; KC_FEATURES+=("${f[@]}") ;;
      *) KC_IGNORED_ARGS+=("${a[i]}") ;;
    esac
  done

  I_MAIN=$(issuer_of "$ISSUERS" main)
  I_ADMIN=$(issuer_of "$ISSUERS" admin)
  I_ADMIN_API=$(issuer_of "$ISSUERS" admin-api)
  local any=${I_MAIN:-$I_ADMIN}
  [[ $any == */realms/* ]] || die "osie-api does not point at Keycloak realms (issuers: ${ISSUERS:-none})."
  KC_URL=${any%%/realms/*}
  KC_REALMS=()
  for i in "$I_MAIN" "$I_ADMIN" "$I_ADMIN_API"; do
    [[ $i == "$KC_URL"/realms/* ]] && KC_REALMS+=("${i##*/realms/}")
  done
  mapfile -t KC_REALMS < <(printf '%s\n' "${KC_REALMS[@]}" | awk 'NF && !seen[$0]++')
  UI_ACCOUNT=; ADMIN_ACCOUNT=
  [[ -n $UI_NAME ]] && UI_ACCOUNT=$(container_env "deployment/$UI_NAME" "$(k get deploy "$UI_NAME" -o jsonpath='{.spec.template.spec.containers[0].name}')" OSIE_OAUTH2_USER_ACCOUNT_CONSOLE)
  [[ -n $ADMIN_NAME ]] && ADMIN_ACCOUNT=$(container_env "deployment/$ADMIN_NAME" "$(k get deploy "$ADMIN_NAME" -o jsonpath='{.spec.template.spec.containers[0].name}')" OSIE_OAUTH2_USER_ACCOUNT_CONSOLE)

  discover_keycloak_extensions
  KC_SVC=$KC_STS
  k get svc "$KC_SVC" >/dev/null 2>&1 || die "Service $KC_SVC is missing."
  KC_INGRESS=
  k get ingress "$KC_STS" >/dev/null 2>&1 && KC_INGRESS=$KC_STS
  KC_SVC_SELECTOR=$(k get svc "$KC_SVC" -o jsonpath='{.spec.selector}')
  KC_SVC_PORTS=$(k get svc "$KC_SVC" -o jsonpath='{.spec.ports}')
  for i in "$KEYCLOAK_NAME" "$KEYCLOAK_DB_NAME"; do
    k get keycloak "$i" >/dev/null 2>&1 && die "A Keycloak named '$i' already exists in $NAMESPACE. Set KEYCLOAK_NAME to another name."
    k get cluster.postgresql.cnpg.io "$i" >/dev/null 2>&1 && die "A CloudNativePG cluster named '$i' already exists in $NAMESPACE. Set KEYCLOAK_DB_NAME to another name."
  done
  local db_size
  db_size=$(printf '%s\n' "$KC_DB_PASSWORD" | k exec -i "$PG_POD" -c postgresql -- bash -c 'read -r PGPASSWORD; export PGPASSWORD; psql -h 127.0.0.1 -p "$1" -U "$2" -d "$3" -tAc "select pg_database_size(current_database())"' _ "$KC_DB_PORT" "$KC_DB_USER" "$KC_DB_NAME" 2>/dev/null | tail -1) || db_size=
  [[ $db_size =~ ^[0-9]+$ ]] || db_size=
  ok "Keycloak: $KC_STS ($KC_IMAGE_OLD) on $KC_DB_HOST, database '$KC_DB_NAME'${db_size:+, $(( db_size / 1048576 )) MiB}"
  ok "Keycloak URL stays $KC_URL (realms: ${KC_REALMS[*]})"
}

discover_keycloak_extensions() {
  local name path sub new vol json
  KC_KEEP_VOLUMES=() KC_MOUNTS_JSON=() KC_EXT_LINES=()
  while IFS=$'\t' read -r name path sub; do
    [[ -z $name ]] && continue
    if [[ $path =~ ^/opt/bitnami/keycloak/(themes|providers)(/|$) ]]; then
      new=/opt/keycloak/${path#/opt/bitnami/keycloak/}
      json=$(k get "$KC_WL" -o jsonpath="{.spec.template.spec.containers[?(@.name==\"keycloak\")].volumeMounts[?(@.mountPath==\"$path\")]}")
      KC_MOUNTS_JSON+=("${json//"/opt/bitnami/keycloak/"/"/opt/keycloak/"}")
      KC_KEEP_VOLUMES+=("$name")
      KC_EXT_LINES+=("$new (volume $name)")
    else
      warn "Keycloak mount $path (volume $name) is not carried over."
    fi
  done < <(k get "$KC_WL" -o go-template='{{range .spec.template.spec.containers}}{{if eq .name "keycloak"}}{{range .volumeMounts}}{{.name}}{{"\t"}}{{.mountPath}}{{"\t"}}{{with .subPath}}{{.}}{{end}}{{"\n"}}{{end}}{{end}}{{end}}')
  KC_INIT_JSON=
  if ((${#KC_KEEP_VOLUMES[@]})); then
    KC_INIT_JSON=$(k get "$KC_WL" -o jsonpath='{.spec.template.spec.initContainers}')
    KC_INIT_JSON=${KC_INIT_JSON//"/opt/bitnami/keycloak/"/"/opt/keycloak/"}
    while read -r vol; do
      [[ -n $vol ]] && KC_KEEP_VOLUMES+=("$vol")
    done < <(k get "$KC_WL" -o go-template='{{range .spec.template.spec.initContainers}}{{range .volumeMounts}}{{.name}}{{"\n"}}{{end}}{{end}}')
    local images
    images=$(k get "$KC_WL" -o jsonpath='{range .spec.template.spec.initContainers[*]}{.image}{" "}{end}')
    [[ -n $images ]] && KC_EXT_LINES+=("filled by init container ${images% }")
  fi
  mapfile -t KC_KEEP_VOLUMES < <(printf '%s\n' "${KC_KEEP_VOLUMES[@]}" | awk 'NF && !seen[$0]++')
  KC_VOLUMES_JSON=()
  for vol in "${KC_KEEP_VOLUMES[@]}"; do
    json=$(k get "$KC_WL" -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"$vol\")]}")
    [[ -n $json ]] && KC_VOLUMES_JSON+=("$json")
  done
  return 0
}

pull_chart() {
  step chart "Getting chart osie $CHART_VERSION"
  mkdir -p "$WORKDIR/chart"
  if [[ -n $OSIE_CHART && ( -f $OSIE_CHART || -d $OSIE_CHART ) ]]; then
    CHART=$OSIE_CHART
  elif [[ -n $OSIE_CHART ]]; then
    hm pull "$OSIE_CHART" --version "$CHART_VERSION" -d "$WORKDIR/chart" >/dev/null || die "Could not pull $OSIE_CHART $CHART_VERSION."
    CHART=$(ls "$WORKDIR"/chart/*.tgz | sed -n 1p)
  else
    hm pull osie --repo "$OSIE_CHART_REPO" --version "$CHART_VERSION" -d "$WORKDIR/chart" >/dev/null \
      || die "Could not download chart osie $CHART_VERSION from $OSIE_CHART_REPO. Set OSIE_CHART to the chart: a .tgz, a directory, repo/chart or oci://..."
    CHART=$(ls "$WORKDIR"/chart/osie-*.tgz | sed -n 1p)
  fi
  local v
  v=$(hm show chart "$CHART" | sed -n 's/^version: *//p')
  [[ $v == "$CHART_VERSION" ]] || die "Chart $CHART is version $v, but the release runs $CHART_VERSION. Use the same version, so only the services change."
  ok "$CHART"
}

write_values() {
  VALUES=$WORKDIR/values.migrated.yaml
  {
    say "# Merge this into the values file you deploy OSIE with."
    if [[ -n $MONGO_WL ]]; then
      say "mongodb:"
      say "  enabled: false"
      say "externalMongodb:"
      say "  hosts: \"$MONGODB_NAME-rs0\""
      say "  port: 27017"
      say "  database: \"$MONGO_DB\""
      say "  extraQueryParams: \"authSource=admin&replicaSet=rs0\""
      say "  existingSecret: \"$MONGODB_NAME-users\""
      say "  existingSecretUsernameKey: MONGODB_DATABASE_ADMIN_USER"
      say "  existingSecretPasswordKey: MONGODB_DATABASE_ADMIN_PASSWORD"
    fi
    if [[ -n $RABBIT_WL ]]; then
      say "rabbitmq:"
      say "  enabled: false"
      say "externalRabbitmq:"
      say "  host: \"$RABBITMQ_NAME\""
      say "  port: 5672"
      say "  vhost: \"/\""
      say "  existingSecret: \"$RABBITMQ_NAME-default-user\""
      say "  existingSecretUsernameKey: username"
      say "  existingSecretPasswordKey: password"
    fi
    if [[ -n $KC_WL ]]; then
      say "keycloak:"
      say "  enabled: false"
      say "global:"
      say "  oauth2:"
      say "    issuerUri: \"\""
      say "ui:"
      say "  oauth2:"
      say "    issuerUri: \"$I_MAIN\""
      say "    accountConsoleUrl: \"$UI_ACCOUNT\""
      say "admin:"
      say "  oauth2:"
      say "    issuerUri: \"$I_ADMIN\""
      say "    accountConsoleUrl: \"$ADMIN_ACCOUNT\""
      say "adminApi:"
      say "  oauth2:"
      say "    issuerUri: \"$I_ADMIN_API\""
    fi
  } >"$VALUES"
}

render_doc() {
  local kind=$1 name=$2 f
  for f in "$WORKDIR"/render/*.yaml; do
    grep -q "^kind: $kind\$" "$f" && grep -q "^  name: $name\$" "$f" && { echo "$f"; return 0; }
  done
  return 1
}

auth_env() {
  grep '^OSIE_OAUTH2' | sort
}

check_render() {
  step render "Checking that only the services change"
  rm -rf "$WORKDIR/render"; mkdir -p "$WORKDIR/render"
  hm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" --reuse-values -f "$VALUES" "${HM_APPLY[@]}" --dry-run=server >"$WORKDIR/render.txt" 2>"$WORKDIR/render.err" \
    || { cat "$WORKDIR/render.err" >&2; die "helm cannot render the release with the migrated values."; }
  awk -v d="$WORKDIR/render" '/^MANIFEST:/ { m = 1; next } m && /^NOTES:/ { exit } m && /^---/ { n++ } m && n { print > (d "/" sprintf("%03d", n) ".yaml") }' "$WORKDIR/render.txt"
  local f new old ui_container
  f=$(render_doc ConfigMap "$API_NAME-config") || die "The rendered release has no ConfigMap $API_NAME-config."
  new=$(k create --dry-run=client -f "$f" -o go-template='{{index .data "application.yml"}}' | issuers_from)
  if [[ "$new" != "$ISSUERS" ]]; then
    say "  before:"; sed 's/^/    /' <<<"$ISSUERS"
    say "  after:"; sed 's/^/    /' <<<"$new"
    die "The issuers osie-api trusts would change. Nothing was touched."
  fi
  ok "osie-api keeps its issuers"
  for d in "$UI_NAME" "$ADMIN_NAME"; do
    [[ -z $d ]] && continue
    f=$(render_doc Deployment "$d") || die "The rendered release has no Deployment $d."
    old=$(k get deploy "$d" -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | auth_env)
    new=$(k create --dry-run=client -f "$f" -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' | auth_env)
    if [[ "$new" != "$old" ]]; then
      diff <(echo "$old") <(echo "$new") | sed 's/^/    /' || true
      die "The sign-in settings of $d would change. Nothing was touched."
    fi
    ok "$d keeps its sign-in settings"
  done
}

plan_operator() {
  local key=$1 label=$2 crd=$3 where=$4
  if kc get crd "$crd" >/dev/null 2>&1; then
    REUSED_OPERATORS+=("$key")
    OPERATOR_LINES+=("$label: uses the operator already installed; it and its CRD stay untouched")
  else
    [[ $INSTALL_OPERATORS == 1 ]] || die "No $label operator is installed ($crd is missing). Install it, or run without INSTALL_OPERATORS=0."
    NEED_OPERATORS+=("$key")
    OPERATOR_LINES+=("$label: installs $where")
  fi
}

check_operators() {
  NEED_OPERATORS=() REUSED_OPERATORS=() OPERATOR_LINES=()
  [[ -z $MONGO_WL ]] || plan_operator psmdb "Percona MongoDB" perconaservermongodbs.psmdb.percona.com \
    "$PSMDB_OPERATOR_VERSION in namespace percona-mongodb, watching all namespaces"
  [[ -z $RABBIT_WL ]] || plan_operator rabbitmq RabbitMQ rabbitmqclusters.rabbitmq.com \
    "cluster operator ${RABBITMQ_OPERATOR_VERSION#v} in namespace rabbitmq-system, watching all namespaces"
  if [[ -n $KC_WL ]]; then
    plan_operator cnpg CloudNativePG clusters.postgresql.cnpg.io "$CNPG_VERSION in namespace cnpg-system, watching all namespaces"
    plan_operator keycloak Keycloak keycloaks.k8s.keycloak.org "$KEYCLOAK_OPERATOR_VERSION in namespace $NAMESPACE"
  fi
  local key out
  for key in "${REUSED_OPERATORS[@]}"; do
    out=$("${key}_manifest" | k apply --dry-run=server --validate=strict -f - 2>&1 >/dev/null) \
      || die "The cluster's $key CRD refuses what the script would create, so its operator is older than the script supports. Upgrade that operator, then run again.
$out"
  done
  return 0
}

served_within() {
  local kind=$1 name=$2 since=$3
  (( SECONDS - since < 180 )) && return 0
  [[ -n $(k get "$kind" "$name" -o jsonpath='{.status}' 2>/dev/null) ]] && return 0
  die "Nothing is handling $kind '$name' in namespace $NAMESPACE: no operator gave it a status within 3 minutes. Start that operator for this namespace, then run again."
}

show_plan() {
  step plan "Plan"
  [[ -n $CLUSTER_DESC ]] && note "Cluster   $CLUSTER_DESC"
  note "Release   $RELEASE in $NAMESPACE (chart $CHART_VERSION, revision $REVISION)"
  if [[ -n $MONGO_WL ]]; then
    note "MongoDB   ${MONGO_WL#*/}  →  Percona MongoDB '$MONGODB_NAME', replica set rs0 of 3, $MONGO_TARGET_SIZE each${MONGO_SC:+, class $MONGO_SC}"
  fi
  if [[ -n $RABBIT_WL ]]; then
    note "RabbitMQ  $RABBIT_SVC  →  RabbitmqCluster '$RABBITMQ_NAME', $RABBIT_TARGET_SIZE${RABBIT_SC:+, class $RABBIT_SC}"
  fi
  if [[ -n $KC_WL ]]; then
    note "Keycloak  $KC_STS  →  Keycloak '$KEYCLOAK_NAME' ${KEYCLOAK_IMAGE:-$KEYCLOAK_OPERATOR_VERSION} on CloudNativePG '$KEYCLOAK_DB_NAME', $PG_TARGET_SIZE${PG_SC:+, class $PG_SC}"
    note "          same URL $KC_URL, same users, passwords, OTP, keys and realms"
    local l
    for l in "${KC_EXT_LINES[@]}"; do note "          themes/providers: $l"; done
    ((${#KC_FEATURES[@]})) && note "          features: ${KC_FEATURES[*]}"
    ((${#KC_IGNORED_ARGS[@]})) && warn "Keycloak arguments not carried over: ${KC_IGNORED_ARGS[*]}"
  fi
  local o
  for o in "${OPERATOR_LINES[@]}"; do note "Operator  $o"; done
  note ""
  note "osie-api is stopped while the data is copied, then started on the new services."
  note "If a step fails, everything goes back the way it was. Log and files: $WORKDIR"
}

confirm() {
  [[ $ASSUME_YES == 1 ]] && return 0
  [[ -t 0 ]] || die "Not asking without a terminal. Run with --yes to start."
  local a
  read -r -p "$(printf '\n%sType yes to start: %s' "$BOLD" "$RESET")" a
  [[ $a == yes ]] || die "Stopped. Nothing was changed."
}

undo_push() { local q; q=$(printf '%q ' "$@"); printf '%s\n' "$q" >>"$WORKDIR/undo"; }

u_delete() {
  local try
  for try in 1 2 3; do
    [[ -n $(k get "$1" "$2" -o name 2>/dev/null) ]] || return 0
    k delete "$1" "$2" --ignore-not-found --wait=true --timeout=10m
    sleep 5
  done
  [[ -z $(k get "$1" "$2" -o name 2>/dev/null) ]] || { warn "$1 '$2' was created again by its operator after each delete; delete it by hand."; return 1; }
}
u_delete_pvcs() {
  local pvc
  for pvc in $(k get pvc -l "app.kubernetes.io/instance!=$RELEASE" -o name 2>/dev/null); do
    [[ ${pvc#*/} == "$1"* ]] && k delete "$pvc" --ignore-not-found --wait=false
  done
  return 0
}
u_scale() { k get "$1" >/dev/null 2>&1 && k scale "$1" --replicas="$2"; return 0; }
u_pv_policy() { kc patch pv "$1" -p "{\"spec\":{\"persistentVolumeReclaimPolicy\":\"$2\"}}" >/dev/null; }
u_unkeep() { k annotate "$1" "$2" helm.sh/resource-policy- >/dev/null 2>&1 || true; }
u_service() {
  k get svc "$1" >/dev/null 2>&1 || return 0
  k patch svc "$1" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":$2},{\"op\":\"replace\",\"path\":\"/spec/ports\",\"value\":$3}]" >/dev/null
}
u_before_helm_rollback() {
  local svc=$1 ing=$2 pvc=$3 pv
  [[ -n $svc ]] && k delete svc "$svc" --ignore-not-found --wait=true
  [[ -n $ing ]] && k delete ingress "$ing" --ignore-not-found --wait=true
  if [[ -n $pvc ]] && k get pvc "$pvc" >/dev/null 2>&1; then
    pv=$(k get pvc "$pvc" -o jsonpath='{.spec.volumeName}')
    k delete pvc "$pvc" --wait=true --timeout=5m
    kc patch pv "$pv" --type=json -p '[{"op":"remove","path":"/spec/claimRef/uid"},{"op":"remove","path":"/spec/claimRef/resourceVersion"}]' >/dev/null
  fi
  return 0
}
u_helm_rollback() { hm rollback "$RELEASE" "$1" -n "$NAMESPACE" "${HM_APPLY[@]}" --wait --timeout "$TIMEOUT"; }
u_delete_tripwires() { k delete configmap,secret -l "$MARK=$RELEASE,osie.io/role=tripwire" --ignore-not-found; }
u_marker() { k delete configmap "$RELEASE-bundled-migration" --ignore-not-found >/dev/null; }

rollback() {
  trap '' INT TERM
  [[ -s $WORKDIR/undo ]] || { ok "Nothing to undo."; return 0; }
  step rollback "Putting everything back"
  local lines=() failed=() i
  mapfile -t lines <"$WORKDIR/undo"
  for ((i = ${#lines[@]} - 1; i >= 0; i--)); do
    [[ -z ${lines[i]} ]] && continue
    note "${DIM}${lines[i]:0:100}${RESET}"
    if ! eval "${lines[i]}"; then
      warn "This step failed: ${lines[i]}"
      failed=("${lines[i]}" "${failed[@]}")
    fi
  done
  if ((${#failed[@]})); then
    printf '%s\n' "${failed[@]}" >"$WORKDIR/undo"
    die "Some steps could not be undone. Fix what they report, then run: bash migrate.sh rollback --workdir $WORKDIR"
  fi
  : >"$WORKDIR/undo"
  local wl waited=1
  for wl in $(k get deploy,sts -l "app.kubernetes.io/instance=$RELEASE" -o name 2>/dev/null); do
    k rollout status "$wl" --timeout="$TIMEOUT" >/dev/null 2>&1 || { warn "$wl is not ready yet."; waited=0; }
  done
  ((waited)) && ok "Every workload of $RELEASE is ready again."
  ok "Back to the bundled services. The new services and their copies were removed; the operators stay installed."
}

on_exit() {
  local rc=$?
  trap - EXIT
  if ((rc != 0 && MUTATED == 1 && COMMITTED == 0)) && [[ $COMMAND == migrate ]]; then
    printf '\n%sFailed during step: %s%s\n' "$RED" "$CURRENT_STEP" "$RESET" >&2
    rollback || true
  fi
  exit "$rc"
}

save_context() {
  {
    printf 'RELEASE=%q\nNAMESPACE=%q\nREVISION=%q\nMONGODB_NAME=%q\nRABBITMQ_NAME=%q\n' "$RELEASE" "$NAMESPACE" "$REVISION" "$MONGODB_NAME" "$RABBITMQ_NAME"
    printf 'KEYCLOAK_NAME=%q\nKEYCLOAK_DB_NAME=%q\nTIMEOUT=%q\n' "$KEYCLOAK_NAME" "$KEYCLOAK_DB_NAME" "$TIMEOUT"
    printf 'KUBECTL=%q\nHELM=%q\nKUBECONFIG_USED=%q\nKUBE_CONTEXT=%q\n' "${KC[*]}" "${HM[*]}" "${KUBECONFIG:-}" "$KUBE_CONTEXT"
    printf 'CLUSTER_ID=%q\nCLUSTER_DESC=%q\n' "$CLUSTER_ID" "$CLUSTER_DESC"
  } >"$WORKDIR/context"
}

start_marker() {
  local existing
  existing=$(cm_value "$RELEASE-bundled-migration" status)
  if [[ -n $existing ]]; then
    die "Release $RELEASE has a migration marked '$existing' (ConfigMap $RELEASE-bundled-migration). If a previous run crashed, run 'bash migrate.sh rollback' from where it ran."
  fi
  MUTATED=1
  k create configmap "$RELEASE-bundled-migration" --from-literal=status=running \
    --from-literal=started="$(date -u +%FT%TZ)" --from-literal=host="$(hostname)" --from-literal=workdir="$WORKDIR" >/dev/null
  k label configmap "$RELEASE-bundled-migration" "$MARK=$RELEASE" >/dev/null
  undo_push u_marker
}

install_operators() {
  ((${#NEED_OPERATORS[@]})) || return 0
  step operators "Installing operators"
  local o
  for o in "${NEED_OPERATORS[@]}"; do
    case $o in
      psmdb)
        hm upgrade --install percona-mongodb-operator psmdb-operator --repo https://percona.github.io/percona-helm-charts \
          --version "$PSMDB_OPERATOR_VERSION" -n percona-mongodb --create-namespace --set watchAllNamespaces=true --wait --timeout "$TIMEOUT" >/dev/null
        ok "Percona MongoDB operator $PSMDB_OPERATOR_VERSION" ;;
      rabbitmq)
        kc apply -f "https://github.com/rabbitmq/cluster-operator/releases/download/$RABBITMQ_OPERATOR_VERSION/cluster-operator.yml" >/dev/null
        kc -n rabbitmq-system rollout status deploy/rabbitmq-cluster-operator --timeout="$TIMEOUT" >/dev/null
        ok "RabbitMQ cluster operator $RABBITMQ_OPERATOR_VERSION" ;;
      cnpg)
        kc apply --server-side -f "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG_VERSION/cnpg-$CNPG_VERSION.yaml" >/dev/null
        kc -n cnpg-system rollout status deploy/cnpg-controller-manager --timeout="$TIMEOUT" >/dev/null
        ok "CloudNativePG $CNPG_VERSION" ;;
      keycloak)
        local base=https://raw.githubusercontent.com/keycloak/keycloak-k8s-resources/$KEYCLOAK_OPERATOR_VERSION/kubernetes crd
        command -v curl >/dev/null 2>&1 || die "Installing the Keycloak operator needs curl."
        for crd in keycloaks keycloakrealmimports keycloakoidcclients keycloaksamlclients; do
          kc get crd "$crd.k8s.keycloak.org" >/dev/null 2>&1 || kc apply -f "$base/$crd.k8s.keycloak.org-v1.yml" >/dev/null
        done
        curl -fsSL "$base/kubernetes.yml" \
          | sed -e "s/name: keycloak-operator-clusterrole-binding\$/name: keycloak-operator-clusterrole-binding-$NAMESPACE/" \
                -e "s/^    namespace: keycloak\$/    namespace: $NAMESPACE/" >"$WORKDIR/keycloak-operator.yml"
        k apply -f "$WORKDIR/keycloak-operator.yml" >/dev/null
        k rollout status deploy/keycloak-operator --timeout="$TIMEOUT" >/dev/null
        ok "Keycloak operator $KEYCLOAK_OPERATOR_VERSION in $NAMESPACE" ;;
    esac
  done
  checkpoint operators
}

protect_volumes() {
  step protect "Protecting the old volumes"
  local pvc pv policy
  for pvc in "${MONGO_PVCS[@]}" "${RABBIT_PVCS[@]}" "${PG_PVCS[@]}"; do
    [[ -z $pvc ]] && continue
    pv=$(k get pvc "$pvc" -o jsonpath='{.spec.volumeName}')
    [[ -z $pv ]] && continue
    policy=$(kc get pv "$pv" -o jsonpath='{.spec.persistentVolumeReclaimPolicy}')
    if [[ $policy != Retain ]]; then
      undo_push u_pv_policy "$pv" "$policy"
      u_pv_policy "$pv" Retain
    fi
    ok "$pvc keeps its volume $pv"
  done
  if [[ -n $MONGO_STANDALONE_PVC ]]; then
    undo_push u_unkeep pvc "$MONGO_STANDALONE_PVC"
    k annotate pvc "$MONGO_STANDALONE_PVC" helm.sh/resource-policy=keep --overwrite >/dev/null
  fi
  checkpoint protect
}

wait_until() {
  local what=$1 check=$2 fail=${3:-true} deadline
  deadline=$(( SECONDS + $(to_seconds "$TIMEOUT") ))
  until $check; do
    $fail || die "$what failed."
    (( SECONDS > deadline )) && die "Timed out after $TIMEOUT waiting for $what."
    sleep 5
  done
}

psmdb_manifest() {
  local sc=${MONGO_SC:+          storageClassName: $MONGO_SC}
  cat <<EOF
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDB
metadata:
  name: $MONGODB_NAME
  labels:
    $MARK: $RELEASE
spec:
  image: $PSMDB_IMAGE
  secrets:
    users: $MONGODB_NAME-users
  sharding:
    enabled: false
  replsets:
    - name: rs0
      size: 3
      affinity:
        antiAffinityTopologyKey: $([[ $MONGODB_HA == 1 ]] && echo kubernetes.io/hostname || echo none)
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          memory: $MONGODB_MEMORY
      volumeSpec:
        persistentVolumeClaim:
$sc
          resources:
            requests:
              storage: $MONGO_TARGET_SIZE
      expose:
        enabled: true
        type: ClusterIP
EOF
}

rabbitmq_manifest() {
  local sc=${RABBIT_SC:+    storageClassName: $RABBIT_SC}
  cat <<EOF
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: $RABBITMQ_NAME
  labels:
    $MARK: $RELEASE
spec:
  replicas: $([[ ${RABBIT_REPLICAS:-1} -ge 3 ]] && echo 3 || echo 1)
  persistence:
    storage: $RABBIT_TARGET_SIZE
$sc
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 1Gi
  rabbitmq:
    additionalPlugins:
      - rabbitmq_management
      - rabbitmq_prometheus
EOF
}

create_targets() {
  step targets "Creating the new services (osie keeps running)"
  local t0=$SECONDS s mongo_err=
  if [[ -n $MONGO_WL ]]; then
    for s in "$MONGODB_NAME-users" "internal-$MONGODB_NAME-users"; do
      k get secret "$s" >/dev/null 2>&1 || undo_push u_delete secret "$s"
    done
    undo_push u_delete_pvcs "mongod-data-$MONGODB_NAME-rs0-"
    undo_push u_delete psmdb "$MONGODB_NAME"
    psmdb_manifest | k apply -f - >/dev/null
    note "Percona MongoDB '$MONGODB_NAME' created"
  fi
  if [[ -n $RABBIT_WL ]]; then
    undo_push u_delete_pvcs "persistence-$RABBITMQ_NAME-server-"
    undo_push u_delete rabbitmqcluster "$RABBITMQ_NAME"
    rabbitmq_manifest | k apply -f - >/dev/null
    note "RabbitmqCluster '$RABBITMQ_NAME' created"
  fi
  if [[ -n $MONGO_WL ]]; then
    mongo_ready() { [[ $(k get psmdb "$MONGODB_NAME" -o jsonpath='{.status.state}' 2>/dev/null) == ready ]]; }
    mongo_ok() {
      if [[ $(k get psmdb "$MONGODB_NAME" -o jsonpath='{.status.state}' 2>/dev/null) == error ]]; then
        mongo_err=${mongo_err:-$SECONDS}
        if (( SECONDS - mongo_err >= 180 )); then
          note "$(k get psmdb "$MONGODB_NAME" -o jsonpath='{.status.message}' 2>/dev/null)"
          return 1
        fi
      else
        mongo_err=
      fi
      served_within psmdb "$MONGODB_NAME" "$t0"
    }
    wait_until "Percona MongoDB '$MONGODB_NAME'" mongo_ready mongo_ok
    ok "Percona MongoDB '$MONGODB_NAME' is ready"
  fi
  if [[ -n $RABBIT_WL ]]; then
    rabbit_ready() { [[ $(k get rabbitmqcluster "$RABBITMQ_NAME" -o jsonpath='{.status.conditions[?(@.type=="AllReplicasReady")].status}' 2>/dev/null) == True ]]; }
    rabbit_ok() { served_within rabbitmqcluster "$RABBITMQ_NAME" "$t0"; }
    wait_until "RabbitmqCluster '$RABBITMQ_NAME'" rabbit_ready rabbit_ok
    ok "RabbitmqCluster '$RABBITMQ_NAME' is ready"
  fi
  checkpoint targets
}

stop_workload() {
  local wl=$1 sel=$2 replicas=$3
  undo_push u_scale "$wl" "$replicas"
  k scale "$wl" --replicas=0 >/dev/null
  k wait --for=delete pod -l "$sel" --timeout="$TIMEOUT" >/dev/null 2>&1 || true
  [[ -z $(k get pod -l "$sel" -o name 2>/dev/null) ]] || die "$wl did not stop."
}

stop_writers() {
  step stop "Stopping osie-api (downtime starts)"
  DOWNTIME_START=$SECONDS
  stop_workload "statefulset/$API_NAME" "$API_SEL" "$API_REPLICAS"
  ok "osie-api stopped"
  if [[ -n $KC_WL ]]; then
    stop_workload "$KC_WL" "$KC_SEL" "$KC_REPLICAS"
    ok "Keycloak stopped"
  fi
  checkpoint stop
}

MONGO_SOURCE_AUTH='set -euo pipefail
  src=(--host 127.0.0.1 --port "${MONGODB_PORT_NUMBER:-27017}")
  if [[ -z ${MONGODB_ROOT_PASSWORD:-} && -n ${MONGODB_ROOT_PASSWORD_FILE:-} ]]; then MONGODB_ROOT_PASSWORD=$(<"$MONGODB_ROOT_PASSWORD_FILE"); fi
  if [[ -n ${MONGODB_ROOT_PASSWORD:-} ]]; then src+=(--username "${MONGODB_ROOT_USER:-root}" --password "$MONGODB_ROOT_PASSWORD" --authenticationDatabase admin); fi
'

MONGO_COUNT_JS='const d = db.getSiblingDB(process.env.DB), now = Number(process.env.NOW);
const ttlOf = c => c.type === "timeseries"
  ? (c.options.expireAfterSeconds !== undefined ? { field: c.options.timeseries.timeField, secs: c.options.expireAfterSeconds } : null)
  : (d.getCollection(c.name).getIndexes().filter(i => i.expireAfterSeconds !== undefined).map(i => ({ field: Object.keys(i.key)[0], secs: i.expireAfterSeconds }))[0] || null);
const lasting = t => t ? { [t.field]: { $gt: new Date(now - (t.secs - 3600) * 1000) } } : {};
d.getCollectionInfos().filter(c => (c.type === "collection" || c.type === "timeseries") && !c.name.startsWith("system."))
  .sort((a, b) => a.name < b.name ? -1 : 1)
  .forEach(c => print(c.name + " " + d.getCollection(c.name).countDocuments(lasting(ttlOf(c)))))'

copy_mongodb() {
  [[ -n $MONGO_WL ]] || return 0
  step mongodb "Copying MongoDB"
  local user pw dst before after
  user=$(secret_value "$MONGODB_NAME-users" MONGODB_DATABASE_ADMIN_USER) || die "Secret $MONGODB_NAME-users has no MONGODB_DATABASE_ADMIN_USER."
  pw=$(secret_value "$MONGODB_NAME-users" MONGODB_DATABASE_ADMIN_PASSWORD) || die "Secret $MONGODB_NAME-users has no MONGODB_DATABASE_ADMIN_PASSWORD."
  dst="rs0/$MONGODB_NAME-rs0.$NAMESPACE.svc.cluster.local:27017"
  if ! printf '%s\n' "$pw" | k exec -i "$MONGO_POD" -c mongodb -- bash -c "$MONGO_SOURCE_AUTH"'
    read -r DST_PW
    mongodump "${src[@]}" --db "$1" --archive --readPreference=nearest \
      | mongorestore --host "$2" --username "$3" --password "$DST_PW" --authenticationDatabase admin \
          --archive --drop --nsInclude "$1.*"
  ' _ "$MONGO_DB" "$dst" "$user" >"$WORKDIR/mongodb-copy.log" 2>&1; then
    tail -15 "$WORKDIR/mongodb-copy.log" | sed 's/^/    /'
    die "Copying MongoDB failed."
  fi
  local now
  now=$(( $(date +%s) * 1000 ))
  before=$(k exec "$MONGO_POD" -c mongodb -- env DB="$MONGO_DB" NOW="$now" bash -c "$MONGO_SOURCE_AUTH"'
    mongosh --quiet "${src[@]}" --eval "$1"' _ "$MONGO_COUNT_JS")
  after=$(printf '%s\n' "$pw" | k exec -i "$MONGO_POD" -c mongodb -- env DB="$MONGO_DB" NOW="$now" bash -c '
    read -r DST_PW
    mongosh --quiet --host "$2" --username "$3" --password "$DST_PW" --authenticationDatabase admin --eval "$1"' _ "$MONGO_COUNT_JS" "$dst" "$user")
  printf '%s\n' "$before" >"$WORKDIR/mongodb-counts.before"
  printf '%s\n' "$after" >"$WORKDIR/mongodb-counts.after"
  [[ -n $before ]] || die "Could not count the documents in the bundled MongoDB."
  if [[ "$before" != "$after" ]]; then
    diff "$WORKDIR/mongodb-counts.before" "$WORKDIR/mongodb-counts.after" | sed 's/^/    /' || true
    die "The copy of MongoDB does not match the original."
  fi
  ok "$(wc -l <<<"$before") collections and $(awk '{s += $2} END {print s}' <<<"$before") documents copied, every count matches (documents due to expire within the hour are not counted)"
  checkpoint mongodb
}

KC_COUNT_SQL="select 'realms', count(*) from realm union all select 'users', count(*) from user_entity union all select 'credentials', count(*) from credential union all select 'clients', count(*) from client union all select 'identity_providers', count(*) from identity_provider union all select 'keys', count(*) from component where provider_type = 'org.keycloak.keys.KeyProvider'"

cnpg_manifest() {
  local sc=${PG_SC:+    storageClass: $PG_SC}
  cat <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: $KEYCLOAK_DB_NAME
  labels:
    $MARK: $RELEASE
spec:
  instances: 1
  imageName: $CNPG_POSTGRES_IMAGE
  storage:
    size: $PG_TARGET_SIZE
$sc
  bootstrap:
    initdb:
      database: $KC_DB_NAME
      owner: $KC_DB_USER
      import:
        type: microservice
        databases:
          - $KC_DB_NAME
        source:
          externalCluster: bundled
  externalClusters:
    - name: bundled
      connectionParameters:
        host: $KC_DB_HOST
        port: "$KC_DB_PORT"
        user: $KC_DB_USER
        dbname: $KC_DB_NAME
      password:
        name: $KEYCLOAK_DB_NAME-import-source
        key: password
EOF
}

copy_keycloak_db() {
  [[ -n $KC_WL ]] || return 0
  step keycloak-db "Copying Keycloak's database"
  local src_secret=$KEYCLOAK_DB_NAME-import-source before after t0
  undo_push u_delete secret "$src_secret"
  k create secret generic "$src_secret" --from-literal=username="$KC_DB_USER" --from-literal=password="$KC_DB_PASSWORD" >/dev/null
  k label secret "$src_secret" "$MARK=$RELEASE" >/dev/null
  if [[ -n $KC_ADMIN_PASSWORD ]]; then
    undo_push u_delete secret "$KEYCLOAK_NAME-bundled-admin"
    k create secret generic "$KEYCLOAK_NAME-bundled-admin" --from-literal=username="${KC_ADMIN_USER:-admin}" --from-literal=password="$KC_ADMIN_PASSWORD" >/dev/null
    k label secret "$KEYCLOAK_NAME-bundled-admin" "$MARK=$RELEASE" >/dev/null
  fi
  undo_push u_delete cluster.postgresql.cnpg.io "$KEYCLOAK_DB_NAME"
  t0=$SECONDS
  cnpg_manifest | k apply -f - >/dev/null
  cnpg_ready() { [[ $(k get cluster.postgresql.cnpg.io "$KEYCLOAK_DB_NAME" -o jsonpath='{.status.phase}' 2>/dev/null) == "Cluster in healthy state" ]]; }
  cnpg_ok() {
    local job
    served_within cluster.postgresql.cnpg.io "$KEYCLOAK_DB_NAME" "$t0"
    job=$({ k get job -l "cnpg.io/cluster=$KEYCLOAK_DB_NAME" -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true; } | sed -n 1p)
    [[ -z $job ]] && return 0
    k logs "job/$job" --tail=30 2>/dev/null | sed 's/^/    /' || true
    return 1
  }
  wait_until "the Keycloak database import" cnpg_ready cnpg_ok
  ok "CloudNativePG '$KEYCLOAK_DB_NAME' imported '$KC_DB_NAME'"
  KC_DB_PRIMARY=$(first_pod "cnpg.io/cluster=$KEYCLOAK_DB_NAME,cnpg.io/instanceRole=primary")
  [[ -n $KC_DB_PRIMARY ]] || die "CloudNativePG '$KEYCLOAK_DB_NAME' has no running primary."
  before=$(printf '%s\n' "$KC_DB_PASSWORD" | k exec -i "$PG_POD" -c postgresql -- bash -c 'read -r PGPASSWORD; export PGPASSWORD; psql -h 127.0.0.1 -p "$1" -U "$2" -d "$3" -tA -F" " -c "$4"' _ "$KC_DB_PORT" "$KC_DB_USER" "$KC_DB_NAME" "$KC_COUNT_SQL")
  after=$(k exec "$KC_DB_PRIMARY" -c postgres -- psql -d "$KC_DB_NAME" -tA -F" " -c "$KC_COUNT_SQL")
  printf '%s\n' "$before" >"$WORKDIR/keycloak-counts.before"
  printf '%s\n' "$after" >"$WORKDIR/keycloak-counts.after"
  [[ -n $before ]] || die "Could not count the rows in Keycloak's database."
  if [[ "$before" != "$after" ]]; then
    diff "$WORKDIR/keycloak-counts.before" "$WORKDIR/keycloak-counts.after" | sed 's/^/    /' || true
    die "The copy of Keycloak's database does not match the original."
  fi
  ok "$(tr '\n' ',' <<<"$before" | sed 's/,$//; s/,/, /g'): every count matches"
  checkpoint keycloak-db
}

keycloak_api_version() {
  local served
  served=$(kc get crd keycloaks.k8s.keycloak.org -o jsonpath='{.spec.versions[?(@.served==true)].name}')
  [[ " $served " == *" v2beta1 "* ]] && echo k8s.keycloak.org/v2beta1 || echo k8s.keycloak.org/v2alpha1
}

join_json() { local IFS=,; printf '[%s]' "$*"; }

keycloak_manifest() {
  local features='' image='' unsupported='' f arr=()
  for f in "${KC_FEATURES[@]}"; do arr+=("$(json_str "$f")"); done
  ((${#arr[@]})) && features=",\"features\":{\"enabled\":$(join_json "${arr[@]}")}"
  [[ -n $KEYCLOAK_IMAGE ]] && image=",\"image\":$(json_str "$KEYCLOAK_IMAGE")"
  if ((${#KC_MOUNTS_JSON[@]})); then
    unsupported=",\"unsupported\":{\"podTemplate\":{\"spec\":{\"initContainers\":${KC_INIT_JSON:-[]},\"containers\":[{\"volumeMounts\":$(join_json "${KC_MOUNTS_JSON[@]}")}],\"volumes\":$(join_json "${KC_VOLUMES_JSON[@]}")}}}"
  fi
  cat <<EOF
{"apiVersion":"$(keycloak_api_version)","kind":"Keycloak",
 "metadata":{"name":$(json_str "$KEYCLOAK_NAME"),"labels":{"$MARK":$(json_str "$RELEASE")}},
 "spec":{"instances":$KC_REPLICAS,
  "db":{"vendor":"postgres","host":"$KEYCLOAK_DB_NAME-rw","port":5432,"database":$(json_str "$KC_DB_NAME"),
        "usernameSecret":{"name":"$KEYCLOAK_DB_NAME-app","key":"username"},
        "passwordSecret":{"name":"$KEYCLOAK_DB_NAME-app","key":"password"}},
  "http":{"httpEnabled":true},
  "hostname":{"hostname":$(json_str "$KC_URL")},
  "proxy":{"headers":"xforwarded"},
  "ingress":{"enabled":false}$features$image$unsupported}}
EOF
}

start_keycloak() {
  [[ -n $KC_WL ]] || return 0
  step keycloak "Starting Keycloak on the copy"
  local t0=$SECONDS
  undo_push u_delete keycloak "$KEYCLOAK_NAME"
  keycloak_manifest | k apply -f - >/dev/null
  kc_ready() { [[ $(k get keycloak "$KEYCLOAK_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; }
  kc_ok() {
    local sel pods p r
    served_within keycloak "$KEYCLOAK_NAME" "$t0"
    sel=$(k get svc "$KEYCLOAK_NAME-service" -o go-template='{{range $k, $v := .spec.selector}}{{$k}}={{$v}},{{end}}' 2>/dev/null | sed 's/,$//')
    [[ -z $sel ]] && return 0
    pods=$(k get pod -l "$sel" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null)
    while read -r p r; do
      if [[ -n $p && ${r:-0} -ge 3 ]]; then
        k logs "$p" --previous --tail=40 2>/dev/null | sed 's/^/    /' || true
        return 1
      fi
    done <<<"$pods"
    return 0
  }
  wait_until "Keycloak '$KEYCLOAK_NAME'" kc_ready kc_ok
  ok "Keycloak '$KEYCLOAK_NAME' is ready (its schema was upgraded on the copy; the original is untouched)"
  local realm got issuer
  for realm in "${KC_REALMS[@]}"; do
    issuer="$KC_URL/realms/$realm"
    got=$(kc get --raw "/api/v1/namespaces/$NAMESPACE/services/http:$KEYCLOAK_NAME-service:8080/proxy/realms/$realm/.well-known/openid-configuration" 2>/dev/null || true)
    [[ $got == *"\"issuer\":\"$issuer\""* ]] || die "Realm '$realm' does not answer with issuer $issuer."
    ok "realm $realm answers as $issuer"
  done
  local m path
  for m in "${KC_MOUNTS_JSON[@]}"; do
    path=$(sed -n 's/.*"mountPath":"\([^"]*\)".*/\1/p' <<<"$m")
    [[ -n $(k exec "$KEYCLOAK_NAME-0" -- ls -A "$path" 2>/dev/null) ]] || die "$path is empty in the new Keycloak."
    ok "$path is in place"
  done
  checkpoint keycloak
}

switch_keycloak_service() {
  [[ -n $KC_WL ]] || return 0
  step service "Pointing $KC_SVC at the new Keycloak"
  local selector ports got
  selector=$(k get svc "$KEYCLOAK_NAME-service" -o jsonpath='{.spec.selector}')
  ports=${KC_SVC_PORTS//\"targetPort\":\"http\"/\"targetPort\":8080}
  undo_push u_service "$KC_SVC" "$KC_SVC_SELECTOR" "$KC_SVC_PORTS"
  undo_push u_unkeep svc "$KC_SVC"
  k annotate svc "$KC_SVC" helm.sh/resource-policy=keep --overwrite >/dev/null
  if [[ -n $KC_INGRESS ]]; then
    undo_push u_unkeep ingress "$KC_INGRESS"
    k annotate ingress "$KC_INGRESS" helm.sh/resource-policy=keep --overwrite >/dev/null
  fi
  u_service "$KC_SVC" "$selector" "$ports"
  got=$(kc get --raw "/api/v1/namespaces/$NAMESPACE/services/http:$KC_SVC:http/proxy/realms/${KC_REALMS[0]}/.well-known/openid-configuration" 2>/dev/null || true)
  [[ $got == *'"issuer"'* ]] || die "$KC_SVC does not reach the new Keycloak."
  ok "$KC_SVC${KC_INGRESS:+ and its Ingress} now lead to the new Keycloak"
  checkpoint service
}

report_queues() {
  [[ -n $RABBIT_WL && -n $RABBIT_POD ]] || return 0
  local busy
  busy=$(k exec "$RABBIT_POD" -c rabbitmq -- rabbitmqctl -q list_queues name messages --formatter=tsv --no-table-headers 2>/dev/null | awk '$2 > 0' || true)
  if [[ -n $busy ]]; then
    note "Messages left in the old RabbitMQ (osie-api queues them again from MongoDB):"
    sed 's/^/    /' <<<"$busy"
  fi
  return 0
}

helm_upgrade() {
  step upgrade "Switching the release to the new services"
  undo_push u_helm_rollback "$REVISION"
  hm upgrade "$RELEASE" "$CHART" -n "$NAMESPACE" --reuse-values -f "$VALUES" "${HM_APPLY[@]}" --wait --timeout "$TIMEOUT" >"$WORKDIR/upgrade.txt" 2>&1 \
    || { tail -20 "$WORKDIR/upgrade.txt" | sed 's/^/    /' >&2; die "helm upgrade failed."; }
  undo_push u_before_helm_rollback "${KC_SVC:-}" "${KC_INGRESS:-}" "${MONGO_STANDALONE_PVC:-}"
  ok "Release $RELEASE upgraded; the bundled services are gone, their volumes are kept"
  checkpoint upgrade
}

health_up() {
  local h
  h=$(kc get --raw "$1" 2>/dev/null) || return 1
  [[ $h == '{"status":"UP"'* || $h == *'"status":"UP"}' ]]
}

api_healthy() {
  local pod base
  pod=$(first_pod "$API_SEL")
  [[ -n $pod ]] || return 1
  base=/api/v1/namespaces/$NAMESPACE/pods/http:$pod:8081/proxy/actuator/health
  health_up "$base" || return 1
  [[ -z $MONGO_WL ]] || health_up "$base/mongo" || return 1
  [[ -z $RABBIT_WL ]] || health_up "$base/rabbit" || return 1
}

start_api() {
  step verify "Starting osie-api on the new services"
  k scale "statefulset/$API_NAME" --replicas="$API_REPLICAS" >/dev/null
  k rollout status "statefulset/$API_NAME" --timeout="$TIMEOUT" >/dev/null || die "osie-api did not come up."
  wait_until "osie-api health" api_healthy
  ok "osie-api is up; MongoDB and RabbitMQ report UP (downtime $(( (SECONDS - DOWNTIME_START) / 60 ))m$(( (SECONDS - DOWNTIME_START) % 60 ))s)"
  checkpoint verify
}

tripwires() {
  local sub kind name msg
  msg="This release moved to operator-managed services on $(date -u +%F). This object makes a helm upgrade that would bring back the bundled services fail, instead of starting OSIE on empty ones. Merge values.migrated.yaml into your values file. To go back on purpose, run: bash migrate.sh rollback"
  hm get manifest "$RELEASE" -n "$NAMESPACE" --revision "$REVISION" | awk '
    /^# Source: / { split($3, p, "/"); sub_ = (p[2] == "charts") ? p[3] : ""; kind = ""; md = 0; next }
    /^kind: / { kind = $2 }
    /^metadata:/ { md = 1; next }
    md && /^  name: / { gsub(/"/, "", $2); if (sub_ != "" && (kind == "ConfigMap" || kind == "Secret") && !seen[sub_]++) print sub_, kind, $2; md = 0 }
  ' | while read -r sub kind name; do
    [[ $sub =~ ^(mongodb|rabbitmq|keycloak|postgresql)$ ]] || continue
    case $sub in
      mongodb) [[ -n $MONGO_WL ]] || continue ;;
      rabbitmq) [[ -n $RABBIT_WL ]] || continue ;;
      *) [[ -n $KC_WL ]] || continue ;;
    esac
    k get "$kind" "$name" >/dev/null 2>&1 && continue
    if [[ $kind == Secret ]]; then
      k create secret generic "$name" --from-literal=README="$msg" >/dev/null
    else
      k create configmap "$name" --from-literal=README="$msg" >/dev/null
    fi
    k label "$kind" "$name" "$MARK=$RELEASE" osie.io/role=tripwire >/dev/null
  done
  return 0
}

commit() {
  step commit "Finishing"
  tripwires
  undo_push u_delete_tripwires
  k patch configmap "$RELEASE-bundled-migration" --type=merge -p "{\"data\":{\"status\":\"migrated\",\"finished\":\"$(date -u +%FT%TZ)\",\"revision\":\"$(current_revision)\"}}" >/dev/null
  COMMITTED=1
  cp "$VALUES" "./values.migrated.$RELEASE.yaml"
  say ""
  say "${GREEN}${BOLD}Done.${RESET} OSIE runs on operator-managed services, with all its data."
  say ""
  say "${BOLD}Do this now:${RESET} merge ./values.migrated.$RELEASE.yaml into the values file you deploy OSIE with."
  say "  Without it, your next 'helm upgrade' would ask for the bundled services again. This run left"
  say "  objects in $NAMESPACE that make such an upgrade fail, so nothing starts on empty databases."
  say "  The error then names one of them, for example 'PASSWORDS ERROR: The secret \"$RELEASE-mongodb\" ...'."
  say ""
  say "Check by hand: sign in to the client portal and the admin as you usually do."
  say "Go back (works until cleanup):   bash migrate.sh rollback --workdir $WORKDIR"
  say "In a week, free the old volumes: bash migrate.sh cleanup --workdir $WORKDIR"
}

latest_workdir() {
  local d
  d=$(ls -d ./osie-migration-* 2>/dev/null | sort | tail -1)
  [[ -n $d ]] || die "No osie-migration-* folder here. Run from where the migration ran, or pass --workdir."
  echo "$d"
}

load_context() {
  [[ -n $WORKDIR ]] || WORKDIR=$(latest_workdir)
  [[ -f $WORKDIR/context ]] || die "$WORKDIR is not a migration folder."
  local asked=$KUBE_CONTEXT
  source "$WORKDIR/context"
  [[ -n $asked ]] && KUBE_CONTEXT=$asked
  [[ -n $KUBECONFIG_USED ]] && export KUBECONFIG=$KUBECONFIG_USED
  read -ra KC <<<"$KUBECTL"
  read -ra HM <<<"$HELM"
  helm_apply_flags
  [[ -z $CLUSTER_ID || $(cluster_id) == "$CLUSTER_ID" ]] \
    || die "This is not the cluster the migration ran on ($CLUSTER_DESC). Pass --context <name>, or set KUBECONFIG."
  exec > >(tee -a "$WORKDIR/migration.log") 2>&1
}

cmd_rollback() {
  load_context
  say "Rolling back the migration of $RELEASE in $NAMESPACE (work folder $WORKDIR)."
  [[ $(cm_value "$RELEASE-bundled-migration" status) == cleaned ]] && die "Cleanup already deleted the old volumes; there is nothing to go back to."
  local left now
  left=$(cm_value "$RELEASE-bundled-migration" revision)
  now=$(current_revision)
  [[ -z $left || $left == "$now" ]] \
    || die "Release $RELEASE changed after the migration (revision $now; the migration left revision $left), for example by an upgrade to a newer chart. Going back would undo that as well, so nothing was changed."
  if [[ $ASSUME_YES != 1 ]]; then
    [[ -t 0 ]] || die "Not asking without a terminal. Run with --yes."
    local a
    read -r -p "Anything written to OSIE since the migration is lost. Type yes to go back: " a
    [[ $a == yes ]] || die "Stopped. Nothing was changed."
  fi
  rollback
}

cmd_cleanup() {
  load_context
  [[ $(cm_value "$RELEASE-bundled-migration" status) == migrated ]] || die "Release $RELEASE has no finished migration to clean up."
  local pvcs pvc pv
  pvcs=$(k get pvc -l "app.kubernetes.io/instance=$RELEASE" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.labels.app\.kubernetes\.io/name}{"\n"}{end}' | awk '$2 ~ /^(mongodb|rabbitmq|postgresql)$/ {print $1}')
  say "This deletes the volumes of the bundled services, so rollback stops working:"
  printf '  %s\n' $pvcs
  if [[ $ASSUME_YES != 1 ]]; then
    [[ -t 0 ]] || die "Not asking without a terminal. Run with --yes."
    local a
    read -r -p "Type the release name ($RELEASE) to delete them: " a
    [[ $a == "$RELEASE" ]] || die "Stopped. Nothing was changed."
  fi
  for pvc in $pvcs; do
    pv=$(k get pvc "$pvc" -o jsonpath='{.spec.volumeName}')
    [[ -n $pv ]] && kc patch pv "$pv" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}' >/dev/null
    k delete pvc "$pvc" --wait=false >/dev/null
    ok "deleted $pvc"
  done
  k delete secret "$KEYCLOAK_DB_NAME-import-source" --ignore-not-found >/dev/null
  k patch configmap "$RELEASE-bundled-migration" --type=merge -p '{"data":{"status":"cleaned"}}' >/dev/null
  : >"$WORKDIR/undo"
  ok "Cleanup done. Keep the tripwire objects until you upgrade to an OSIE chart without bundled services."
}

cmd_migrate() {
  detect_tools
  find_release
  [[ -n $WORKDIR ]] || WORKDIR=./osie-migration-$RELEASE-$(date +%Y%m%d-%H%M%S)
  mkdir -p "$WORKDIR"
  WORKDIR=$(cd "$WORKDIR" && pwd)
  : >>"$WORKDIR/undo"
  exec > >(tee -a "$WORKDIR/migration.log") 2>&1
  save_context
  discover
  pull_chart
  write_values
  check_render
  check_operators
  show_plan
  if [[ $COMMAND == plan ]]; then
    say ""
    ok "Plan only. Nothing was changed. The values it would use: $VALUES"
    return 0
  fi
  confirm
  trap on_exit EXIT
  trap 'exit 130' INT TERM
  start_marker
  install_operators
  protect_volumes
  create_targets
  stop_writers
  copy_mongodb
  copy_keycloak_db
  start_keycloak
  switch_keycloak_service
  report_queues
  helm_upgrade
  start_api
  commit
}

main() {
  parse_args "$@"
  case $COMMAND in
    plan|migrate) cmd_migrate ;;
    rollback) cmd_rollback ;;
    cleanup) cmd_cleanup ;;
  esac
}

main "$@"
