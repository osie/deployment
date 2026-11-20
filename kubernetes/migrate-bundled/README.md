# Moving off the bundled MongoDB, RabbitMQ and Keycloak

Older installs of the `osie` helm chart run MongoDB, RabbitMQ and Keycloak from Bitnami subcharts, which
the chart turned on by default. Bitnami no longer publishes those images, so they get no fixes, and the
chart from 26.9 on no longer includes them: it deploys only OSIE. `migrate.sh` moves a release onto
operator-managed services in one maintenance window, keeping all data:

| Bundled | Becomes |
|---|---|
| MongoDB | a Percona MongoDB replica set |
| RabbitMQ | a RabbitMQ cluster from the RabbitMQ operator |
| Keycloak and its PostgreSQL | Keycloak from the Keycloak operator, on a CloudNativePG database |

Every Keycloak user keeps their password, one-time-password devices, realms, clients, identity providers
and signing keys. Keycloak keeps its address and keys, so users sign in as before and tokens already issued
stay valid until they expire; sessions open at the time end, so users sign in once more. Its theme comes
along: the osie theme of the old chart, your own, or both. The script moves only what the release still
bundles.

## Step by step

```bash
# 1. A folder for this migration. Keep it: rollback and cleanup run from it.
mkdir osie-migration && cd osie-migration

# 2. The script, and a copy of the values file you deploy OSIE with. It is required.
curl -fsSLO https://raw.githubusercontent.com/osie/deployment/main/kubernetes/migrate-bundled/migrate.sh
cp /path/to/your/values.yaml values.yaml
#    No values file? Write one from what the release runs with:
#    helm get values <release> -n <namespace> > values.yaml

# 3. What it would do, on which cluster. Nothing changes.
bash migrate.sh plan --values values.yaml

# 4. The migration, inside tmux or screen so a dropped connection does not interrupt it.
#    It shows the plan again and asks before it starts.
tmux new -s osie-migration
bash migrate.sh --values values.yaml
```

When it is done, the folder holds:

| File | What it is | What to do with it |
|---|---|---|
| `values.yaml` | your values, with the migration's settings merged in by Helm. Comments and key order are not kept | Deploy OSIE with it from now on |
| `values.yaml.before-migration-<time>` | your values file as it was | Keep it until you clean up |
| `mongodb.<release>.yaml`, `rabbitmq.<release>.yaml`, `keycloak.<release>.yaml` | the new services. The Keycloak one holds Keycloak with its theme, its database, Service and Ingress | Keep them with your deployment and manage them from now on. The chart no longer deploys these services. Applying them again changes nothing |
| `values.migrated.<release>.yaml` | only the settings the migration changed | For reference |
| `osie-migration-<release>-<time>/` | the log, the settings it used, the counts before and after, and what rollback needs | Keep it until you clean up |

Then:

5. Sign in to the client portal and the admin as you usually do.
6. If something is wrong, go back: `bash migrate.sh rollback`. This works until you clean up or upgrade the
   release again, and loses whatever was written to OSIE since the migration.
7. Once you are confident, free the old volumes: `bash migrate.sh cleanup`.
8. Upgrade to OSIE 26.9 or later with your new `values.yaml`.

`bash migrate.sh --help` lists every option.

## Before you start

You need:

- bash 4.4 or later (on macOS, `brew install bash`), and cluster-admin rights through the same kubeconfig
  for `kubectl` and `helm` (helm 3.14 or later, or 4)
- the release on chart 26.8 or later (see *When it stops before starting*)
- room in the cluster for the new copies while the old volumes are kept: the new MongoDB has three members,
  each with a full copy, so plan for three times its data, plus a copy of RabbitMQ's and Keycloak's
- internet access for the operators and the chart, unless they are installed already
- a maintenance window: osie-api is stopped from the start of the copy until it runs on the new services.
  For a few gigabytes of data this takes minutes.

It works on the current context of your kubeconfig, and the plan names that cluster before anything
changes. Pass `--context <name>` for another one. It finds the OSIE release by itself; with several, pass
`--release <name> --namespace <namespace>`. The new volumes get the storage class of the old ones; pass
`--storage-class <name>` to move them to another, for example from `local-path` to replicated storage.

It finds `kubectl` and `helm` on the `PATH`, or through microk8s, k3s, k0s and rke2. When neither fits,
name them:

```bash
KUBECTL="microk8s kubectl" HELM="microk8s helm3" bash migrate.sh plan --values values.yaml
KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash migrate.sh plan --values values.yaml
```

## What it does

1. Checks the release and renders it with the new settings, to confirm that only the services change.
   Nothing is touched if that check fails.
2. Installs an operator only when its CRD is missing from the cluster: Percona's in `percona-mongodb`,
   RabbitMQ's in `rabbitmq-system` and CloudNativePG in `cnpg-system`, each watching all namespaces, and the
   Keycloak operator in the release's namespace. Where the CRD exists, it uses the operator already there and
   never changes it or its CRD; it first has the cluster check, without creating anything, that the CRD
   accepts what it will create. The Keycloak operator serves only its own namespace, so when its CRD exists
   but no operator answers in the release's namespace, it installs one there, with its own cluster roles,
   and leaves the CRD and the other operators alone. Going back never removes an operator or a CRD.
3. Sets the old volumes to be kept, whatever happens next.
4. Creates the new MongoDB and RabbitMQ while OSIE keeps running.
5. Stops osie-api and Keycloak, copies MongoDB and Keycloak's database, and compares every collection and
   table count with the original.
6. Starts Keycloak on the copy with its theme, and checks that each realm answers at its old address.
7. Upgrades the release with the same chart version and the new settings, and starts osie-api on the new
   services.
8. Writes your values file and the files of the new services.

If any step fails, you press Ctrl-C, or the connection drops, it undoes everything it did in reverse and
the release is back on the bundled services with its data. The operators stay installed. Fix what it
reported and run it again. Should a step of going back itself fail, it stops there and removes nothing
more, so the old volumes keep their data; fix what it reports and run `bash migrate.sh rollback`.

An upgrade without the new settings would ask for the bundled services again, so the script leaves small
objects in the namespace that make such an upgrade fail before it changes anything. The error names one of
them, for example `PASSWORDS ERROR: The secret "osie-mongodb" does not contain the key …`. Keep them until
you are on chart 26.9 or later.

`rollback` and `cleanup` work from the folder you ran the migration in, or take `--workdir <folder>`. They use
the context the migration used, and refuse to run against any other cluster.

## A Keycloak installed on its own

When OSIE signs in with a Keycloak that was installed separately from the Bitnami chart, the plan of an OSIE
run says so. Move that Keycloak with its own run, in its own folder:

```bash
mkdir keycloak-migration && cd keycloak-migration
curl -fsSLO https://raw.githubusercontent.com/osie/deployment/main/kubernetes/migrate-bundled/migrate.sh
bash migrate.sh plan --release <keycloak-release> --namespace <its-namespace>
bash migrate.sh --release <keycloak-release> --namespace <its-namespace>
```

Its database is copied the same way, and the new Keycloak runs from the operator at the same address, which
the script reads from the release's Ingress, or from `KEYCLOAK_URL`, with its theme. The Bitnami release is
uninstalled with its history kept, so `rollback` can bring it back; its Service and Ingress stay and lead to
the new Keycloak. The folder then holds `keycloak.<release>.yaml`, to keep and manage like the files above.
Applications that use this Keycloak need no change.

## When it stops before starting

| It says | What to do |
|---|---|
| Pass --values | Pass the values file you deploy OSIE with. Without one, write it from what the release runs with: `helm get values <release> -n <namespace> > values.yaml` |
| The release runs a chart older than 26.8.0 | Upgrade OSIE to the latest 26.8 chart the way you usually do, then run it again. Without your values file at hand: `helm upgrade <release> osie --repo https://helm.osie.io --version '~26.8' -n <namespace> --reset-then-reuse-values --wait`, adding `--server-side=false` with helm 4 so changes made with `kubectl edit` do not stop the upgrade halfway |
| The cluster's CRD refuses what the script would create | The operator already installed is too old for it. Upgrade that operator, then run again |
| Nothing is handling a new service (no status within 3 minutes) | No operator watches the release's namespace. Start one for it, or add the namespace to the ones it watches, then run again. The script has already put everything back |
| A storage class does not exist, or there is no default one | Pick one with `--storage-class`, or per service with the variables under *Settings* |
| Keycloak runs your own image | Build one `FROM quay.io/keycloak/keycloak:<version>` with your themes and providers under `/opt/keycloak/`, and set `KEYCLOAK_IMAGE` to it |
| Keycloak uses a database outside this release | The script moves only the bundled PostgreSQL. Contact OSIE support |
| Keycloak has no Ingress, or does not answer at the address it found | Set `KEYCLOAK_URL` to the address users reach it at |
| Keycloak serves under a path such as `/auth` | Not supported by the script. Contact OSIE support |
| Something else points at the bundled RabbitMQ | Plan to point it at `rabbitmq.<namespace>.svc:5672` afterwards, then run again with `ALLOW_RABBITMQ_CLIENTS=1` |
| `MONGODB_HA=1`, but fewer than 3 nodes take pods | Leave `MONGODB_HA` unset, or add nodes |
| osie-api has a HorizontalPodAutoscaler | Set `api.autoscaling.enabled=false`, upgrade, and run again |
| The issuers or sign-in settings would change | Send the log to OSIE support |

## Settings

`bash migrate.sh --help` lists the options. Everything else is an environment variable, for example
`MONGODB_SIZE=50Gi bash migrate.sh --values values.yaml`. Set these where the defaults do not fit; most are
about what cannot be changed once the new services exist.

| Variable | Default | Meaning |
|---|---|---|
| `STORAGE_CLASS` | the class of the old volumes | storage class of all new volumes, the same as `--storage-class` |
| `MONGODB_STORAGE_CLASS`, `RABBITMQ_STORAGE_CLASS`, `KEYCLOAK_DB_STORAGE_CLASS` | `STORAGE_CLASS` | storage class of one service's new volumes |
| `MONGODB_SIZE`, `RABBITMQ_SIZE`, `KEYCLOAK_DB_SIZE` | the old volume's size, at least 10Gi, 5Gi and 5Gi | size of each new volume, like `20Gi`. A volume can grow later only if its class allows it |
| `MONGODB_HA` | `1` when the bundled MongoDB was a replica set and 3 nodes take pods, else `0` | `1` puts the three MongoDB members on different nodes. There are always three |
| `RABBITMQ_REPLICAS` | `3` when the bundled RabbitMQ had 3 or more, else `1` | RabbitMQ nodes, `1` or `3` |
| `MONGODB_IMAGE`, `POSTGRES_IMAGE` | `percona/percona-server-mongodb:7.0.18-11`, `ghcr.io/cloudnative-pg/postgresql:17` | images of the new MongoDB and Keycloak database, for clusters that pull from a mirror |
| `RABBITMQ_IMAGE`, `KEYCLOAK_IMAGE` | the image of the operator | images of the new RabbitMQ and Keycloak |
| `MONGODB_NAME`, `RABBITMQ_NAME`, `KEYCLOAK_NAME`, `KEYCLOAK_DB_NAME` | `mongodb`, `rabbitmq`, `keycloak`, `keycloak-db` | names of the new services |
| `MONGODB_MEMORY` | `2Gi` | memory limit of each MongoDB member |
| `KEYCLOAK_URL` | the host of the Keycloak release's Ingress | for a Keycloak installed on its own: the address users reach it at |
| `KEYCLOAK_CHART` | `oci://registry-1.docker.io/bitnamicharts/keycloak` | for a Keycloak installed on its own: where its chart is, a `.tgz` or a folder without internet |
| `VALUES_FILE` | none, and required for an OSIE release | the same as `--values` |
| `KUBECTL`, `HELM` | found by the script | the commands to run |
| `KUBE_CONTEXT` | the current context | the same as `--context` |
| `OSIE_CHART` | the chart from `OSIE_CHART_REPO` | the osie chart to upgrade with: a `.tgz`, a folder, `repo/chart` or `oci://…`. It must be the version the release runs |
| `OSIE_CHART_REPO` | `https://helm.osie.io` | where to download the chart |
| `INSTALL_OPERATORS` | `1` | `0` is the same as `--no-install-operators`; for clusters without internet, install the operators first |
| `ALLOW_RABBITMQ_CLIENTS` | `0` | `1` goes ahead although workloads other than OSIE use the bundled RabbitMQ |
| `TIMEOUT` | `20m` | how long to wait for each step |
| `ASSUME_YES` | `0` | `1` is the same as `--yes` |

The new services start small, like the single-node manifests in [`../infrastructure`](../infrastructure).
CPU, memory and the number of members can be changed in their files afterwards.
