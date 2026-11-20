# Moving off the bundled MongoDB, RabbitMQ and Keycloak

Older installs of the `osie` helm chart run MongoDB, RabbitMQ and Keycloak from Bitnami subcharts, which
the chart turned on by default. Bitnami no longer publishes those images, so they get no fixes, and a
coming release of the chart removes them. `migrate.sh` moves a release onto the operator-managed services
this guide describes, in one maintenance window:

| Bundled | Becomes |
|---|---|
| MongoDB | a Percona MongoDB replica set |
| RabbitMQ | a RabbitMQ cluster from the RabbitMQ operator |
| Keycloak and its PostgreSQL | Keycloak from the Keycloak operator, on a CloudNativePG database |

Everything is copied: OSIE's data, and every Keycloak user with their password, one-time-password
devices, realms, clients, identity providers and signing keys. Keycloak keeps its address, so users sign
in as before and tokens stay valid. Themes and providers mounted into Keycloak come along. The script
moves only what the release still bundles, so an install on OSIE's own sign-in, or on its own MongoDB,
gets only the remaining steps.

## Run it

```bash
curl -fsSLO https://raw.githubusercontent.com/osie/deployment/main/kubernetes/migrate-bundled/migrate.sh
bash migrate.sh plan     # shows what it would do, changes nothing
bash migrate.sh          # shows the plan again, asks, then migrates
```

It works on the current context of your kubeconfig, and the plan names that cluster before anything
changes. Pass `--context <name>` for another one. It finds the OSIE release by itself. With several, pass
`--release <name> --namespace <namespace>`.

It finds `kubectl` and `helm` on the `PATH`, or through microk8s, k3s, k0s and rke2. When neither fits,
name them:

```bash
KUBECTL="microk8s kubectl" HELM="microk8s helm3" bash migrate.sh
KUBECONFIG=/etc/rancher/k3s/k3s.yaml bash migrate.sh
```

What it needs:

- bash 4.4 or later (on macOS, `brew install bash`), and cluster-admin rights through the same kubeconfig
  for `kubectl` and `helm` (helm 3.14 or later, or 4)
- room in the cluster for a second copy of the data while both exist
- internet access for the operators and the chart, unless they are installed already (see *Settings*)
- a maintenance window: osie-api is stopped from the start of the copy until it runs on the new services.
  For a few gigabytes of data this takes minutes.

## What it does

1. Checks the release and renders it with the new settings, to confirm that only the services change.
   Nothing is touched if that check fails.
2. Installs an operator only when its CRD is missing from the cluster: Percona's in `percona-mongodb`,
   RabbitMQ's in `rabbitmq-system` and CloudNativePG in `cnpg-system`, each watching all namespaces, and the
   Keycloak operator in the release's namespace. Where the CRD exists, it uses the operator already there and
   never changes it or its CRD; it first has the cluster check, without creating anything, that the CRD
   accepts what it will create. Going back never removes an operator or a CRD.
3. Sets the old volumes to be kept, whatever happens next.
4. Creates the new MongoDB and RabbitMQ while OSIE keeps running.
5. Stops osie-api and Keycloak, copies MongoDB and Keycloak's database, and compares every collection and
   table count with the original.
6. Starts Keycloak on the copy, and checks that each realm answers at its old address.
7. Upgrades the release with the same chart version and the new settings, and starts osie-api on the new
   services.

If any step fails, or you press Ctrl-C, it undoes everything it did in reverse and the release is back on
the bundled services with its data. The operators stay installed. Fix what it reported and run it again.

Everything it writes goes to `./osie-migration-<release>-<time>/`: the log, the settings it used, and the
document counts before and after.

## Afterwards

**Merge `values.migrated.<release>.yaml` into the values file you deploy OSIE with.** Without it, the next
`helm upgrade` asks for the bundled services again. The script leaves small objects in the namespace that
make such an upgrade fail before it changes anything, so OSIE never starts on empty databases. The error
names one of them, for example `PASSWORDS ERROR: The secret "osie-mongodb" does not contain the key …`.
Keep them until you move to a chart version without bundled services.

Then sign in to the client portal and the admin as you usually do.

The old volumes stay, so you can go back until you clean up or upgrade the release again. Going back loses
whatever was written to OSIE since the migration:

```bash
bash migrate.sh rollback
```

Once you are confident, free the old volumes:

```bash
bash migrate.sh cleanup
```

Both commands work from the folder you ran the migration in, or take `--workdir <folder>`. They use the
context the migration used, and refuse to run against any other cluster.

## When it stops before starting

| It says | What to do |
|---|---|
| The release runs a chart older than 26.8.0 | Upgrade OSIE to the latest 26.8 chart the way you usually do, then run it again. Without your values file at hand: `helm upgrade <release> osie --repo https://helm.osie.io --version '~26.8' -n <namespace> --reset-then-reuse-values --wait`, adding `--server-side=false` with helm 4 so changes made with `kubectl edit` do not stop the upgrade halfway |
| The cluster's CRD refuses what the script would create | The operator already installed is too old for it. Upgrade that operator, then run again |
| Nothing is handling a new service (no status within 3 minutes) | No operator watches the release's namespace. Start one for it, or add the namespace to the ones it watches, then run again. The script has already put everything back |
| Keycloak runs your own image | Build one `FROM quay.io/keycloak/keycloak:<version>` with your themes and providers under `/opt/keycloak/`, and set `KEYCLOAK_IMAGE` to it |
| Keycloak uses a database outside this release | The script moves only the bundled PostgreSQL. Contact OSIE support |
| Something else points at the bundled RabbitMQ | Plan to point it at `rabbitmq.<namespace>.svc:5672` afterwards, then run again with `ALLOW_RABBITMQ_CLIENTS=1` |
| osie-api has a HorizontalPodAutoscaler | Set `api.autoscaling.enabled=false`, upgrade, and run again |
| The issuers or sign-in settings would change | Send the log to OSIE support |

## Settings

Set these as environment variables.

| Variable | Default | Meaning |
|---|---|---|
| `KUBECTL`, `HELM` | found by the script | the commands to run |
| `KUBE_CONTEXT` | the current context | kubeconfig context to use, the same as `--context` |
| `OSIE_CHART` | the chart from `OSIE_CHART_REPO` | the osie chart to upgrade with: a `.tgz`, a folder, `repo/chart` or `oci://…`. It must be the version the release runs |
| `OSIE_CHART_REPO` | `https://helm.osie.io` | where to download the chart |
| `INSTALL_OPERATORS` | `1` | `0` to refuse to install missing operators |
| `KEYCLOAK_IMAGE` | the operator's Keycloak image | Keycloak image to run |
| `MONGODB_NAME`, `RABBITMQ_NAME`, `KEYCLOAK_NAME`, `KEYCLOAK_DB_NAME` | `mongodb`, `rabbitmq`, `keycloak`, `keycloak-db` | names of the new services |
| `MONGODB_HA` | `0` | `1` puts the three MongoDB members on different nodes |
| `MONGODB_MEMORY` | `2Gi` | memory limit of each MongoDB member |
| `TIMEOUT` | `20m` | how long to wait for each step |
| `ASSUME_YES` | `0` | `1` is the same as `--yes` |

The new services start small, like the single-node manifests in [`../infrastructure`](../infrastructure).
Size them up in place afterwards.
